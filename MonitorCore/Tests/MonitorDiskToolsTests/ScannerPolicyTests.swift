import Darwin
import Foundation
import MonitorModel
import Synchronization
import Testing
@testable import MonitorDiskTools

private func atomicValue(_ counter: borrowing Atomic<Int>) -> Int { counter.load(ordering: .sequentiallyConsistent) }

/// Access policy, walk-rule locations, failure mapping and event discipline (review round 1 of the scanner).
@Suite struct ScannerPolicyTests {
    private func run(_ items: [Item], root: ScanRoot = homeRoot, access: ScanAccessPolicy = fdaGranted,
                     progressInterval: Duration = .milliseconds(100),
                     onList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in })
        async -> (events: [ScanEvent], lister: InMemoryLister) {
        let lister = InMemoryLister(items, onList: onList)
        let scanner = Scanner(lister: lister, threads: 4, home: home, access: access, progressInterval: progressInterval)
        return (await drain(scanner.scan(root: root)), lister)
    }

    private static let library: [Item] = [
        .dir("Library", [
            .dir("Containers", [
                .dir("com.other.App", [.file("data", 3_000_000)]),
                .dir("dev.warden.Own", [.file("data", 2_000_000)]),
            ]),
            .dir("Group Containers", [.dir("group.other", [.file("data", 1_000_000)])]),
            .dir("Application Support", [.dir("Thing", [.file("data", 4_000_000)])]),
        ]),
    ]

    /// Bug: opening another app's container without Full Disk Access raises a consent prompt that blocks the walk
    /// forever. Without a confirmed grant those folders must never be opened; with it they are walked.
    @Test(arguments: [false, true])
    func otherAppsContainersAreOnlyOpenedWithFullDiskAccess(granted: Bool) async throws {
        let (events, lister) = await run(Self.library, access: ScanAccessPolicy(fullDiskAccess: granted))
        let tree = try #require(finishedTree(of: events))
        let attempts = lister.openAttempts.withLock { $0 }
        let guarded = ["Library/Containers/com.other.App", "Library/Group Containers/group.other"]
        for path in guarded {
            #expect(attempts.contains(path) == granted, "\(path)")
            let node = Int(try #require(tree.lookup(path: full(path))))
            #expect(tree.flags[node].contains(.restricted) == !granted, "\(path)")
        }
        #expect(attempts.contains("Library/Containers/dev.warden.Own"))
        #expect(attempts.contains("Library/Application Support/Thing"))
        #expect(tree.allocBytes[0] == (granted ? 10_000_000 : 6_000_000))
    }

    /// Bug: the `~/Library/*` keep rule only worked for a scan rooted at the home folder.
    @Test(arguments: ["/Users/test/Library/Caches", "/System/Volumes/Data/Users/test/Library/Caches"])
    func keepRuleFollowsTheRealLocationOfTheRoot(rootPath: String) async throws {
        let (events, _) = await run([.file("x.plist", 120)], root: .folder(rootPath))
        let tree = try #require(finishedTree(of: events))
        #expect(tree.lookup(path: rootPath + "/x.plist") != nil)
    }

    /// Bug: a device-gone errno on an entry (not on a listing) is shown as one restricted file while the scan
    /// completes, in a normal directory and inside a package alike.
    @Test(arguments: ["directory", "package"])
    func deviceGoneEntryFailsTheScan(where place: String) async {
        let bad = Item(entry: ListedEntry(name: Array("bad".utf8), kind: .other, errorCode: ENXIO), children: [])
        let items = place == "directory" ? [bad] : [.dir("Foo.app", [bad])]
        let (events, _) = await run(items)
        #expect(failure(of: events) == .volumeRemoved)
    }

    /// Bug: a package with an unreadable part is shown with a size that silently leaves that part out.
    @Test(arguments: ["entry", "subdirectory"])
    func unreadablePartMakesThePackageRestricted(part: String) async throws {
        let bad = Item(entry: ListedEntry(name: Array("bad".utf8), kind: .other, errorCode: EACCES), children: [])
        let inside: [Item] = part == "entry" ? [.file("exe", 3_000_000), bad] : [.file("exe", 3_000_000), .dir("inner")]
        let (events, _) = await run([.dir("Foo.app", inside), .file("sibling", 2_000_000)]) { path throws(ListError) in
            if path == "Foo.app/inner" { throw ListError(errno: EACCES, op: "test") }
        }
        let tree = try #require(finishedTree(of: events))
        let node = Int(try #require(tree.lookup(path: full("Foo.app"))))
        #expect(tree.flags[node].contains(.package) && tree.flags[node].contains(.restricted))
        #expect(tree.size(Int32(node)) == nil)
        #expect(tree.allocBytes[0] == 2_000_000)
    }

    /// Bug: a link deep inside a package is recorded at the package's own depth + 1, so it can win the one-time
    /// credit over a link that is really shallower.
    @Test func packageInternalLinksKeepTheirPhysicalDepth() async throws {
        let items = [
            Item.dir("Foo.app", [.dir("a", [.dir("b", [.file("inner", 2_000_000, linkCount: 2, fileID: 9)])])]),
            Item.dir("other", [.file("outer", 2_000_000, linkCount: 2, fileID: 9)]),
        ]
        let (events, _) = await run(items)
        let tree = try #require(finishedTree(of: events))
        let outer = try #require(tree.lookup(path: full("other/outer")))
        let group = try #require(tree.linkGroups.first)
        #expect(group.occurrences.map(\.node).first == outer)
        #expect(group.occurrences.map(\.depth) == [2, 4])
        #expect(tree.allocBytes[0] == 2_000_000)
    }

    /// Bug: a tick or partial snapshot published after the terminal event (a consumer would then see events after
    /// the scan ended). Ticks every millisecond with slow listings make the race likely.
    @Test func nothingIsPublishedAfterTheTerminalEvent() async {
        let items = (0 ..< 6).map { Item.dir("d\($0)", [.file("f", 2_000_000)]) }
        for round in 0 ..< 30 {
            let (events, _) = await run(items, progressInterval: .milliseconds(1)) { path throws(ListError) in
                usleep(UInt32(100 + (round * 37 + path.utf8.count * 11) % 400))
            }
            var terminals: [Int] = []
            for (index, event) in events.enumerated() {
                switch event {
                case .finished, .failed: terminals.append(index)
                default: break
                }
            }
            #expect(terminals == [events.count - 1])
        }
    }

    /// Bug: the root descriptor outlives the scan (success or failure) and holds the volume busy.
    @Test(arguments: [false, true])
    func rootIsReleasedWhenTheScanEnds(failing: Bool) async {
        let (events, lister) = await run([.dir("sub", [.file("f", 2_000_000)])]) { path throws(ListError) in
            if failing, path == "sub" { throw ListError(errno: ENXIO, op: "test") }
        }
        #expect(failing ? failure(of: events) == .volumeRemoved : finishedTree(of: events) != nil)
        #expect(atomicValue(lister.rootAcquired) == 1)
        #expect(atomicValue(lister.rootReleased) == 1)
    }

    /// Bug: the entry counter the probe reports is derived from the tree instead of what the walk enumerated.
    @Test func enumeratedCounterCountsEveryEntry() async {
        let lister = InMemoryLister([.dir("d", [.file("a", 10), .file("b", 20), .file("c", 2_000_000)]), .file("e", 5)])
        let scanner = Scanner(lister: lister, threads: 2, home: home, access: fdaGranted)
        _ = await drain(scanner.scan(root: homeRoot))
        #expect(scanner.enumeratedEntries == 5)
    }
}
