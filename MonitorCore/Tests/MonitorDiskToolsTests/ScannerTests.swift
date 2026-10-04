import Darwin
import Dispatch
import Foundation
import MonitorModel
import Synchronization
import Testing
@testable import MonitorDiskTools

typealias Item = InMemoryLister.Item

/// Blocks a lister call until the test opens the gate.
final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open(_ times: Int = 1) { for _ in 0 ..< times { semaphore.signal() } }
    /// Fails the test instead of hanging when an expected call never happens.
    func awaitEntry(times: Int = 1) -> Bool {
        (0 ..< times).allSatisfy { _ in semaphore.wait(timeout: .now() + 20) == .success }
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func finishedTree(of events: [ScanEvent]) -> StorageTree? {
    if case let .finished(tree) = events.last { return tree }
    return nil
}

func failure(of events: [ScanEvent]) -> ScanFailure? {
    if case let .failed(reason) = events.last { return reason }
    return nil
}

func drain(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
    var events: [ScanEvent] = []
    for await event in stream { events.append(event) }
    return events
}

let fdaGranted = ScanAccessPolicy(fullDiskAccess: true)
let home = "/Users/test"
let homeRoot = ScanRoot.home(home)

private func scan(_ items: [Item], threads: Int = 4, batchSize: Int = 1000,
                  onList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in })
    async -> (events: [ScanEvent], lister: InMemoryLister) {
    let lister = InMemoryLister(items, batchSize: batchSize, onList: onList)
    let events = await drain(Scanner(lister: lister, threads: threads, home: home, access: fdaGranted).scan(root: homeRoot))
    return (events, lister)
}

func full(_ relative: String) -> String { home + "/" + relative }

@Suite struct ScannerTests {
    // MARK: Random trees

    private struct RandomTree {
        var items: [Item]
        /// Directory path (relative, "" = root) → total bytes of every file below it.
        var totals: [String: UInt64]
    }

    private static func randomTree(seed: UInt64) -> RandomTree {
        var rng = SplitMix(state: seed)
        var totals: [String: UInt64] = [:]
        func make(path: String, depth: Int) -> ([Item], UInt64) {
            var items: [Item] = []
            var sum: UInt64 = 0
            for i in 0 ..< Int.random(in: 0 ... 6, using: &rng) {
                let name = "n\(i)"
                if depth < 4, Int.random(in: 0 ..< 10, using: &rng) < 4 {
                    let childPath = path.isEmpty ? name : path + "/" + name
                    let (children, bytes) = make(path: childPath, depth: depth + 1)
                    totals[childPath] = bytes
                    sum += bytes
                    items.append(.dir(name, children))
                } else {
                    let bytes = Int.random(in: 0 ..< 10, using: &rng) < 3
                        ? UInt64.random(in: 1_000_000 ... 5_000_000, using: &rng)
                        : UInt64.random(in: 100 ... 900_000, using: &rng)
                    sum += bytes
                    items.append(.file(name, bytes, mtime: Int64.random(in: 1 ... 1000, using: &rng)))
                }
            }
            return (items, sum)
        }
        let (items, sum) = make(path: "", depth: 0)
        totals[""] = sum
        return RandomTree(items: items, totals: totals)
    }

    private static func latency(seed: UInt64, path: String) -> UInt32 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ seed
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return UInt32(hash % 300)
    }

    /// Bug: concurrent commits interleave or lose children, or sizes depend on completion order.
    @Test(arguments: 0 ..< 50)
    func randomTreesRollUpToNaiveSums(seed: Int) async throws {
        let random = Self.randomTree(seed: UInt64(seed))
        let (events, lister) = await scan(random.items, threads: 8) { path throws(ListError) in
            usleep(Self.latency(seed: UInt64(seed), path: path))
        }
        let tree = try #require(finishedTree(of: events))
        for (path, expected) in random.totals {
            let node = try #require(tree.lookup(path: path.isEmpty ? home : full(path)), "\(path)")
            #expect(tree.allocBytes[Int(node)] == expected, "\(path)")
        }
        for node in 1 ..< tree.nodeCount { #expect(tree.parent[node] < Int32(node)) }
        for node in 0 ..< tree.nodeCount where tree.childCount[node] > 0 {
            for k in 0 ..< Int(tree.childCount[node]) {
                #expect(tree.parent[Int(tree.firstChild[node]) + k] == Int32(node))
            }
        }
        #expect(lister.opened.load(ordering: .sequentiallyConsistent) == lister.closed.load(ordering: .sequentiallyConsistent))
    }

    /// Bug: a directory listed in several batches gets its children split around another listing's.
    @Test func multiBatchListingsStayContiguous() async throws {
        let random = Self.randomTree(seed: 7)
        let (events, _) = await scan(random.items, threads: 8, batchSize: 2)
        let tree = try #require(finishedTree(of: events))
        #expect(tree.allocBytes[0] == random.totals[""])
        for node in 0 ..< tree.nodeCount where tree.childCount[node] > 0 {
            for k in 0 ..< Int(tree.childCount[node]) {
                #expect(tree.parent[Int(tree.firstChild[node]) + k] == Int32(node))
            }
        }
    }

    // MARK: Termination

    /// Bug: done is declared while a listing is still in flight, so the children it is about to push are never walked.
    @Test func nothingFinishesWhileAListingIsInFlight() async throws {
        let blocked = Gate()
        let entered = Gate()
        let siblingListed = Gate()
        let items = [
            Item.dir("d1"),
            Item.dir("d2", [.dir("deep", [.file("big.bin", 3_000_000)])]),
        ]
        let lister = InMemoryLister(items) { path throws(ListError) in
            if path == "d2" {
                entered.open()
                blocked.wait()
            } else if path == "d1" {
                siblingListed.open()
            }
        }
        let scanner = Scanner(lister: lister, threads: 2, home: home, access: fdaGranted)
        let stream = scanner.scan(root: homeRoot)
        #expect(entered.awaitEntry())
        #expect(siblingListed.awaitEntry())
        var terminalBeforeRelease = false
        var progressTicks = 0
        var released = false
        var events: [ScanEvent] = []
        for await event in stream {
            events.append(event)
            switch event {
            case .finished, .failed: if !released { terminalBeforeRelease = true }
            case .progress:
                // The second tick (100 ms apart) is ample time for the sibling's worker to finish and, with the
                // bug, to declare the queue drained while d2 is still in flight.
                progressTicks += 1
                if progressTicks == 2, !released { released = true; blocked.open() }
            default: break
            }
        }
        #expect(!terminalBeforeRelease)
        let tree = try #require(finishedTree(of: events))
        let deep = try #require(tree.lookup(path: full("d2/deep/big.bin")))
        #expect(tree.allocBytes[Int(deep)] == 3_000_000)
        #expect(tree.allocBytes[0] == 3_000_000)
    }

    /// Bug: a root that is still being listed lets the scan end early or empty.
    @Test func blockedRootListingDelaysFinish() async throws {
        let blocked = Gate()
        let entered = Gate()
        let lister = InMemoryLister([.file("a.bin", 2_000_000)]) { path throws(ListError) in
            if path.isEmpty {
                entered.open()
                blocked.wait()
            }
        }
        let stream = Scanner(lister: lister, threads: 8, home: home, access: fdaGranted).scan(root: homeRoot)
        #expect(entered.awaitEntry())
        var terminalBeforeRelease = false
        var released = false
        var events: [ScanEvent] = []
        for await event in stream {
            events.append(event)
            switch event {
            case .finished, .failed: if !released { terminalBeforeRelease = true }
            case .progress: if !released { released = true; blocked.open() }
            default: break
            }
        }
        #expect(!terminalBeforeRelease)
        #expect(finishedTree(of: events)?.allocBytes[0] == 2_000_000)
    }

    /// Bug: cancel waits for workers stuck in a syscall (a consent prompt never answered): with two workers held
    /// inside listings for the whole test, the stream must still yield `.failed(.cancelled)` and finish, the root
    /// must be released, and when the workers eventually leave they must not walk anything further or leak a handle.
    /// The gate is opened only at the end.
    @Test func cancelCompletesWhileWorkersAreHeldAndStopsFurtherWork() async throws {
        let heldEntered = Gate()
        let freeListed = Gate()
        let hold = Gate()
        let items = [
            Item.dir("H1", [.dir("late1", [.file("f", 2_000_000)])]),
            Item.dir("H2", [.dir("late2", [.file("f", 2_000_000)])]),
        ] + (0 ..< 6).map { Item.dir("free\($0)", [.file("f", 2_000_000)]) }
        let lister = InMemoryLister(items) { path throws(ListError) in
            if path == "H1" || path == "H2" {
                heldEntered.open()
                hold.wait()
            } else if path.hasPrefix("free") {
                freeListed.open()
            }
        }
        let scanner = Scanner(lister: lister, threads: 8, home: home, access: fdaGranted)
        let stream = scanner.scan(root: homeRoot)
        #expect(heldEntered.awaitEntry(times: 2))
        #expect(freeListed.awaitEntry(times: 6))
        scanner.cancel()

        // Both workers are still held: the stream ends anyway.
        let events = await drain(stream)
        #expect(failure(of: events) == .cancelled)
        #expect(lister.rootReleased.load(ordering: .sequentiallyConsistent) == 1)

        hold.open(2)
        // Workers leave on their own threads: wait (bounded) until every handle they held is closed.
        let deadline = Date().addingTimeInterval(10)
        while lister.opened.load(ordering: .sequentiallyConsistent) != lister.closed.load(ordering: .sequentiallyConsistent),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(lister.opened.load(ordering: .sequentiallyConsistent) == lister.closed.load(ordering: .sequentiallyConsistent))
        let listed = lister.listedPaths.withLock { $0 }
        #expect(!listed.contains("H1/late1") && !listed.contains("H2/late2"))
    }

    // MARK: Hard links

    /// Bug: link bytes land on whichever worker saw the link first, so sizes change from run to run.
    @Test func hardLinkBytesGoToTheShallowestOccurrenceEveryRun() async throws {
        let items = [
            Item.dir("a", [.file("shallow", 2_000_000, linkCount: 2, fileID: 99)]),
            Item.dir("b", [.dir("c", [.dir("d", [.file("deep", 2_000_000, linkCount: 2, fileID: 99)])])]),
        ]
        var seen: Set<[String: UInt64]> = []
        for run in 0 ..< 20 {
            let (events, _) = await scan(items, threads: 8) { path throws(ListError) in
                usleep(Self.latency(seed: UInt64(run), path: path))
            }
            let tree = try #require(finishedTree(of: events))
            let shallow = try #require(tree.lookup(path: full("a/shallow")))
            let group = try #require(tree.linkGroups.first)
            #expect(group.occurrences.first?.node == shallow)
            #expect(tree.allocBytes[Int(shallow)] == 2_000_000)
            #expect(group.linkCount == 2)
            var sizes: [String: UInt64] = [:]
            for node in 0 ..< tree.nodeCount { sizes[tree.path(Int32(node))] = tree.allocBytes[node] }
            seen.insert(sizes)
        }
        #expect(seen.count == 1)
        #expect(try #require(seen.first)[full("b")] == 0)
    }

    // MARK: Keep rules

    /// Bug: leftovers cannot see plists, because small files were folded away.
    @Test func smallFilesFoldExceptLibraryChildren() async throws {
        let items = [
            Item.dir("Library", [
                .dir("Preferences", [.file("x.plist", 120)]),
                .dir("Other", [.file("y.txt", 80, mtime: 50), .file("z.txt", 20, mtime: 90)]),
            ]),
            Item.dir("Docs", [.file("big.bin", 1_000_000), .file("tiny", 10)]),
        ]
        let (events, _) = await scan(items)
        let tree = try #require(finishedTree(of: events))
        let plist = try #require(tree.lookup(path: full("Library/Preferences/x.plist")))
        #expect(tree.allocBytes[Int(plist)] == 120)
        #expect(tree.lookup(path: full("Library/Other/y.txt")) == nil)
        let other = try #require(tree.lookup(path: full("Library/Other")))
        #expect(tree.smallBytes[Int(other)] == 100)
        #expect(tree.smallCount[Int(other)] == 2)
        #expect(tree.subtreeMaxMtime[Int(other)] == 90)
        let docs = try #require(tree.lookup(path: full("Docs")))
        #expect(tree.smallCount[Int(docs)] == 1)
        #expect(tree.lookup(path: full("Docs/big.bin")) != nil)
    }

    /// Bug: a fresh `node_modules` makes a stale project look recently used.
    @Test func markersAndBuildDirMtime() async throws {
        let items = [
            Item.dir("proj", mtime: 100, [
                .dir(".git", mtime: 100),
                .file("package.json", 50, mtime: 100),
                .dir("src", mtime: 100, [.file("old.txt", 10, mtime: 100)]),
                .dir("node_modules", mtime: 2_000_000_000, [.file("fresh.js", 10, mtime: 2_000_000_000)]),
            ]),
        ]
        let (events, _) = await scan(items)
        let tree = try #require(finishedTree(of: events))
        let proj = Int(try #require(tree.lookup(path: full("proj"))))
        #expect(tree.markerMask[proj] == [.git, .packageJSON])
        let modules = Int(try #require(tree.lookup(path: full("proj/node_modules"))))
        #expect(tree.flags[modules].contains(.buildDir))
        #expect(tree.subtreeMaxMtime[proj] == 100)
        #expect(tree.subtreeMaxMtime[modules] == 2_000_000_000)
    }

    // MARK: Walk rules

    enum Rule: CaseIterable {
        case unreadableDir, datalessDir, mountPoint, autofsTrigger, spotlightIndex, package
    }

    /// Bugs: one unreadable dir aborts the scan; a listing downloads an iCloud placeholder; the walk enters
    /// `/Volumes`-style mounts; package internals are shown as folders.
    @Test(arguments: Rule.allCases)
    func walkRules(_ rule: Rule) async throws {
        var items = [Item.file("sibling.bin", 2_000_000)]
        switch rule {
        case .unreadableDir: items.append(.dir("locked", [.file("hidden.bin", 5_000_000)]))
        case .datalessDir: items.append(.dir("cloud", fileFlags: UInt32(SF_DATALESS), [.file("remote.bin", 5_000_000)]))
        case .mountPoint:
            items.append(.dir("Volumes", mountStatus: UInt32(DIR_MNTSTATUS_MNTPOINT), [.file("disk.bin", 5_000_000)]))
        case .autofsTrigger:
            items.append(.dir("home", mountStatus: UInt32(DIR_MNTSTATUS_TRIGGER), [.file("net.bin", 5_000_000)]))
        case .spotlightIndex: items.append(.dir(".Spotlight-V100", [.file("index", 5_000_000)]))
        case .package:
            items.append(.dir("Foo.app", [.dir("Contents", [.file("exe", 3_000_000), .file("tiny", 1_000)])]))
        }
        let (events, lister) = await scan(items) { path throws(ListError) in
            if path == "locked" { throw ListError(errno: EACCES, op: "test") }
        }
        let tree = try #require(finishedTree(of: events))
        let listed = lister.listedPaths.withLock { $0 }
        #expect(tree.allocBytes[0] == (rule == .package ? 2_000_000 + 3_001_000 : 2_000_000))
        switch rule {
        case .unreadableDir:
            let node = Int(try #require(tree.lookup(path: full("locked"))))
            #expect(tree.flags[node].contains(.restricted))
            #expect(tree.size(Int32(node)) == nil)
        case .datalessDir:
            #expect(!listed.contains("cloud"))
            #expect(tree.flags[Int(try #require(tree.lookup(path: full("cloud"))))].contains(.dataless))
        case .mountPoint:
            #expect(!listed.contains("Volumes"))
            #expect(tree.flags[Int(try #require(tree.lookup(path: full("Volumes"))))].contains(.skippedMount))
        case .autofsTrigger:
            #expect(!listed.contains("home"))
            #expect(tree.flags[Int(try #require(tree.lookup(path: full("home"))))].contains(.skippedMount))
        case .spotlightIndex:
            #expect(!listed.contains(".Spotlight-V100"))
        case .package:
            let node = Int(try #require(tree.lookup(path: full("Foo.app"))))
            #expect(tree.flags[node].contains(.package))
            #expect(tree.childCount[node] == 0)
            #expect(tree.allocBytes[node] == 3_001_000)
            #expect(tree.markerMask[node] == [])
        }
    }

    // MARK: Volume removal

    /// Bug: an eject of the scanned volume is ignored, so the scan keeps the volume busy.
    @Test func unmountOfTheRootVolumeCancelsTheScan() async throws {
        let entered = Gate()
        let proceed = Gate()
        let lister = InMemoryLister([.dir("sub", [.file("f", 2_000_000)])]) { path throws(ListError) in
            if path == "sub" {
                entered.open()
                proceed.wait()
            }
        }
        let (unmounts, send) = AsyncStream.makeStream(of: String.self)
        let scanner = Scanner(lister: lister, threads: 2, home: home, access: fdaGranted)
        let stream = scanner.scan(root: .volume(path: "/Volumes/Backup", name: "Backup"), willUnmount: unmounts)
        #expect(entered.awaitEntry())
        send.yield("/Volumes/Other")
        send.yield("/Volumes/Backup")
        // The terminal event does not wait for the worker held in `sub`; it is released only at the end.
        let events = await drain(stream)
        proceed.open()
        #expect(failure(of: events) == .volumeRemoved)
    }

    /// Bug: a forced removal surfaces as a partial tree treated as complete.
    @Test(arguments: [ENXIO, EIO, ENODEV])
    func deviceGoneErrorFailsTheScan(_ code: Int32) async {
        let (events, _) = await scan([.dir("sub", [.file("f", 2_000_000)])]) { path throws(ListError) in
            if path == "sub" { throw ListError(errno: code, op: "test") }
        }
        #expect(failure(of: events) == .volumeRemoved)
    }

    /// Bug: prefix matching treats `/Volumes/Backup2` as the volume `/Volumes/Backup`.
    @Test func unmountMatchesWholeComponents() {
        #expect(VolumeWatch.unmountAffects(mountPath: "/Volumes/Backup", rootPath: "/Volumes/Backup"))
        #expect(VolumeWatch.unmountAffects(mountPath: "/Volumes/Backup", rootPath: "/Volumes/Backup/Photos"))
        #expect(!VolumeWatch.unmountAffects(mountPath: "/Volumes/Backup", rootPath: "/Volumes/Backup2"))
        #expect(!VolumeWatch.unmountAffects(mountPath: "/", rootPath: "/Users/test"))
    }
}
