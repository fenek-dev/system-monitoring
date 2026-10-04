import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct ClassifierTests {
    typealias F = ClassifierFixture
    typealias T = TreeFixture

    private static func appSupport(_ children: [T.Entry]) -> [T.Entry] {
        [T.dir("Library", [T.dir("Application Support", children)])]
    }

    // MARK: Ownership

    /// Bug caught: an app found only through `appPaths` (odd location, helper-only) loses its data to Leftovers; or
    /// leftovers listed before the platform lookup ran.
    @Test func leftoversNeedPlatformLookup() {
        let classifier = F.classifier()
        let result = F.classify(Self.appSupport([
            F.aged("com.found.app", days: 200), F.aged("com.gone.app", days: 200),
        ]), classifier: classifier)

        #expect(result.unresolvedBundleIDs == ["com.found.app", "com.gone.app"])
        #expect(result.set.items.isEmpty)
        #expect(!result.set.ownershipResolved)

        let resolved = classifier.resolve(result, found: ["com.found.app": ["/Opt/Found.app"], "com.gone.app": []])
        #expect(F.paths(resolved, .leftovers) == ["/Users/test/Library/Application Support/com.gone.app"])
        #expect(resolved.ownershipResolved)
        #expect(resolved.items.map(\.id) == [0])
    }

    /// Bug caught: an installed app's data (vendor / helper IDs) offered as a leftover.
    @Test func installedOwnerHidesData() {
        let installed = InstalledAppSet(ids: ["com.foo.app": OwnerApp(bundleID: "com.foo.app", name: "Foo")])
        let result = F.classify(Self.appSupport([
            F.aged("com.foo.app.helper", days: 200), F.aged("com.foobar.app", days: 200),
        ]), installed: installed)
        #expect(result.unresolvedBundleIDs == ["com.foobar.app"])
    }

    /// Bug caught: off-by-one in the 90 day age gate (fresh data offered, or stale data hidden).
    @Test(arguments: [(89.0, false), (91.0, true)])
    func leftoverAgeGate(days: Double, offered: Bool) {
        let result = F.classify(Self.appSupport([F.aged("com.gone.app", days: days)]))
        #expect(result.unresolvedBundleIDs == (offered ? ["com.gone.app"] : []))
    }

    // MARK: User Caches

    /// Bug caught: system caches and Apple data deleted (iCloud, Maps, Wallet breakage), or the Xcode cache that is
    /// explicitly allowed hidden.
    @Test(arguments: [
        ("com.foo.app", true), ("com.apple.dt.Xcode", true), ("Arc", true),
        ("com.apple.Safari", false), ("CloudKit", false), ("com.apple.bird", false), ("GeoServices", false),
        ("findmy.cache", false), ("ap.adprivacyd", false), ("akd", false),
    ])
    func userCacheExclusions(name: String, offered: Bool) {
        let result = F.classify([T.dir("Library", [T.dir("Caches", [F.aged(name, days: 1)])])])
        #expect(F.paths(result.set, .userCaches) == (offered ? ["/Users/test/Library/Caches/\(name)"] : []))
    }

    @Test func userCacheItemShape() throws {
        let installed = InstalledAppSet(ids: ["com.foo.app": OwnerApp(bundleID: "com.foo.app", name: "Foo")])
        let tree = T.build([T.dir("Library", [T.dir("Caches", [F.aged("com.foo.app.cache", days: 1, bytes: 777)])])])
        let result = F.classifier().classify(tree: tree, installed: installed, lastUsed: [:],
                                             options: ClassifyOptions(now: F.now))
        let item = try #require(result.set.items.first)
        #expect(item.tier == .safe)
        #expect(item.mode == .remove)
        #expect(item.keepParent)
        #expect(item.owner?.name == "Foo")
        #expect(item.allocBytes == 777)
        #expect(item.identity == tree.identity(try #require(item.nodeID)))
        #expect(item.parentID == nil)
    }

    // MARK: Own data

    /// Bug caught: deleting our own store or staging dir, or an item that contains it.
    @Test func ownDataNeverOffered() {
        let result = F.classify(
            [T.dir("Library", [
                T.dir("Application Support", [F.aged("dev.warden", days: 300), F.aged("com.other.gone", days: 300)]),
                T.dir("Caches", [
                    F.aged("dev.telltale-dev", days: 1, [F.aged("wt", days: 1)]),
                    F.aged("com.apple.dt.Xcode", days: 1),
                    F.aged("com.foo.cache", days: 1, [F.aged("Staging", days: 1)]),
                    F.aged("com.bar.cache", days: 1),
                ]),
            ])],
            classifier: F.classifier(dataDirectories: ["/Users/test/Library/Caches/com.foo.cache/Staging"]))
        #expect(F.paths(result.set, .userCaches) == [
            "/Users/test/Library/Caches/com.apple.dt.Xcode", "/Users/test/Library/Caches/com.bar.cache",
        ])
        #expect(result.unresolvedBundleIDs == ["com.other.gone"])
    }

    // MARK: Large & Old

    enum Place { case documents, library, hidden, insideApp }

    struct LargeOldCase: CustomTestStringConvertible {
        var label: String
        var bytes: UInt64
        var mtimeDays: Double
        var addedDays: Double? = nil
        var spotlightDays: Double? = nil
        var place = Place.documents
        var ubiquitous = false
        var expected: DeleteMode?
        var testDescription: String { label }
    }

    /// Bug caught: threshold off-by-one, recent files trashed by mtime alone, iCloud files trashed instead of
    /// evicted, files inside bundles / `~/Library` / hidden dirs offered.
    @Test(arguments: [
        LargeOldCase(label: "500 MB recent", bytes: 500_000_000, mtimeDays: 1, expected: .trash),
        LargeOldCase(label: "499.99 MB recent", bytes: 499_999_999, mtimeDays: 1, expected: nil),
        LargeOldCase(label: "50 MB at 183 d", bytes: 50_000_000, mtimeDays: 183, expected: .trash),
        LargeOldCase(label: "50 MB at 182 d", bytes: 50_000_000, mtimeDays: 182, expected: nil),
        LargeOldCase(label: "49.99 MB ancient", bytes: 49_999_999, mtimeDays: 900, expected: nil),
        LargeOldCase(label: "old mtime, recent addedTime", bytes: 60_000_000, mtimeDays: 900, addedDays: 1,
                     expected: nil),
        LargeOldCase(label: "old mtime, recent Spotlight use", bytes: 60_000_000, mtimeDays: 900,
                     spotlightDays: 2, expected: nil),
        LargeOldCase(label: "old, old Spotlight", bytes: 60_000_000, mtimeDays: 900, spotlightDays: 400,
                     expected: .trash),
        LargeOldCase(label: "huge in ~/Library", bytes: 900_000_000, mtimeDays: 900, place: .library, expected: nil),
        LargeOldCase(label: "huge in hidden dir", bytes: 900_000_000, mtimeDays: 900, place: .hidden, expected: nil),
        LargeOldCase(label: "huge inside .app", bytes: 900_000_000, mtimeDays: 900, place: .insideApp, expected: nil),
        LargeOldCase(label: "iCloud file", bytes: 900_000_000, mtimeDays: 900, ubiquitous: true, expected: .evict),
    ])
    func largeOld(_ c: LargeOldCase) {
        let file = T.file("blob.bin", c.bytes, mtime: F.ago(c.mtimeDays), added: c.addedDays.map(F.ago) ?? 0)
        let entries: [T.Entry] = switch c.place {
        case .documents: [T.dir("Documents", [file])]
        case .library: [T.dir("Library", [T.dir("Movies", [file])])]
        case .hidden: [T.dir(".stash", [file])]
        case .insideApp: [T.dir("Documents", [T.dir("X.app", flags: .package, [file])])]
        }
        let path = "/Users/test/Documents/blob.bin"
        let result = F.classify(
            entries, lastUsed: c.spotlightDays.map { [path: Date(timeIntervalSince1970: Double(F.ago($0)))] } ?? [:],
            classifier: F.classifier(ubiquitous: c.ubiquitous ? [path] : []))
        let items = result.set.items.filter { $0.category == .largeOld }
        #expect(items.map(\.mode) == (c.expected.map { [$0] } ?? []))
        if c.expected != nil { #expect(items.first?.path == path) }
    }

    // MARK: Nesting

    /// Bug caught: one node offered in two categories (double count, double delete).
    @Test func sameNodeGoesToHigherPriority() {
        let result = F.classify([T.dir("Library", [T.dir("Caches", [F.aged("com.gone.app", days: 200)])])])
        #expect(F.paths(result.set, .userCaches) == ["/Users/test/Library/Caches/com.gone.app"])
        #expect(result.unresolvedBundleIDs.isEmpty)
    }

    /// Bug caught: a gone app's container offered twice (container as Leftover and its Caches as User Caches).
    @Test(arguments: [(false, ["/Users/test/Library/Containers/com.gone.app"], CleanupCategory.leftovers),
                      (true, ["/Users/test/Library/Containers/com.gone.app/Data/Library/Caches/blob"],
                       CleanupCategory.userCaches)])
    func containerCaches(installedApp: Bool, expected: [String], category: CleanupCategory) {
        let installed = installedApp
            ? InstalledAppSet(ids: ["com.gone.app": OwnerApp(bundleID: "com.gone.app", name: "Gone")])
            : InstalledAppSet(ids: [:])
        let tree = T.build([T.dir("Library", [T.dir("Containers", [
            F.aged("com.gone.app", days: 200, [T.dir("Data", [T.dir("Library", [T.dir("Caches", [
                T.file("blob", 5000, mtime: F.ago(200)),
            ])])])]),
        ])])])
        let classifier = F.classifier()
        let result = classifier.classify(tree: tree, installed: installed, lastUsed: [:],
                                         options: ClassifyOptions(now: F.now))
        let set = classifier.resolve(result, found: [:])
        #expect(F.paths(set) == expected)
        #expect(set.items.first?.category == category)
    }

    // MARK: Ignored

    /// Bug caught: ignoring is one-way (an unignored path stays hidden) or drops the item.
    @Test func ignoredRoundTrip() {
        let entries = [T.dir("Library", [T.dir("Caches", [F.aged("com.foo.app", days: 1)])])]
        let path = "/Users/test/Library/Caches/com.foo.app"
        let ignored = F.classify(entries, options: ClassifyOptions(now: F.now, ignoredPaths: [path]))
        #expect(ignored.set.items.map(\.ignored) == [true])
        #expect(F.paths(ignored.set) == [path])
        let back = F.classify(entries, options: ClassifyOptions(now: F.now, ignoredPaths: []))
        #expect(back.set.items.map(\.ignored) == [false])
    }

    // MARK: Developer

    private static let xcode = "Library/Developer/Xcode"

    /// Bug caught: all device-support dirs offered, deleting the only copy a connected device needs.
    @Test func deviceSupportKeepsNewest() {
        let result = F.classify([T.dir("Library", [T.dir("Developer", [T.dir("Xcode", [
            T.dir("iOS DeviceSupport", [
                F.aged("17.0 (21A)", days: 300), F.aged("18.0 (22A)", days: 5), F.aged("17.5 (21F)", days: 100),
            ]),
            T.dir("watchOS DeviceSupport", [F.aged("11.0", days: 50)]),
        ])])])])
        #expect(F.paths(result.set, .developer) == [
            "/Users/test/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A)",
            "/Users/test/Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F)",
        ])
        #expect(result.set.items.map(\.tier) == [.review, .review])
        #expect(result.set.items.map(\.mode) == [.remove, .remove])
    }

    /// Bug caught: Safe tier on archives, or fresh archives offered.
    @Test func archivesByAge() {
        let result = F.classify([T.dir("Library", [T.dir("Developer", [T.dir("Xcode", [T.dir("Archives", [
            T.dir("2026-01-01", [F.aged("Old.xcarchive", days: 181), F.aged("New.xcarchive", days: 179)]),
        ])])])])])
        #expect(F.paths(result.set, .developer) == ["/Users/test/Library/Developer/Xcode/Archives/2026-01-01/Old.xcarchive"])
        #expect(result.set.items.map(\.tier) == [.review])
        #expect(result.set.items.map(\.mode) == [.trash])
    }

    @Test func safeDeveloperCaches() {
        let result = F.classify([
            T.dir("Library", [T.dir("Developer", [T.dir("Xcode", [F.aged("DerivedData", days: 1)])]),
                              T.dir("Caches", [F.aged("Homebrew", days: 1)])]),
            T.dir(".npm", [F.aged("_cacache", days: 1)]),
        ])
        // Homebrew sits in ~/Library/Caches too: Developer outranks User Caches for the same node.
        #expect(F.paths(result.set) == [
            "/Users/test/.npm/_cacache", "/Users/test/Library/Caches/Homebrew",
            "/Users/test/Library/Developer/Xcode/DerivedData",
        ])
        #expect(result.set.items.map(\.category) == [.developer, .developer, .developer])
        #expect(result.set.items.map(\.tier) == [.safe, .safe, .safe])
        #expect(result.set.items.map(\.mode) == [.remove, .remove, .remove])
    }

    /// Bug caught: bare `xcrun` run without a selected toolchain (triggers the CLT install prompt); or the Docker
    /// image offered for deletion.
    @Test(arguments: [true, false])
    func simulatorsAndDocker(xcodeOK: Bool) {
        let dev = FakeDevTools(xcodeSelectOK: xcodeOK, udids: ["DEAD-1", "DEAD-2"])
        let result = F.classify([T.dir("Library", [
            T.dir("Developer", [T.dir("CoreSimulator", [T.dir("Devices", [
                F.aged("DEAD-1", days: 1, bytes: 300), F.aged("DEAD-2", days: 1, bytes: 400),
                F.aged("LIVE-3", days: 1, bytes: 9000),
            ])])]),
            T.dir("Containers", [T.dir("com.docker.docker", [T.dir("Data", [T.dir("vms", [T.dir("0", [
                T.dir("data", [T.file("Docker.raw", 8000, mtime: F.ago(1))]),
            ])])])])]),
        ])], classifier: F.classifier(devTools: dev))
        let sims = result.set.items.filter { $0.mode == .simctl }
        #expect(sims.map(\.allocBytes) == (xcodeOK ? [700] : []))
        #expect(dev.simulatorQueries == (xcodeOK ? 1 : 0))
        let docker = result.set.items.filter { $0.mode == DeleteMode.none }
        #expect(docker.map(\.allocBytes) == [8000])
        #expect(docker.first?.note?.contains("docker system prune") == true)
    }

    // MARK: Trash

    /// Bug caught: Trash size missing/ wrong when readable; phantom row when unreadable.
    @Test func trash() {
        let readable = F.classify([T.dir(".Trash", [T.file("a", 123, mtime: F.ago(1))])])
        #expect(readable.set.trashBytes == 123)
        #expect(readable.set.items.map(\.category) == [.trash])
        #expect(readable.set.items.map(\.tier) == [.review])
        #expect(readable.set.items.map(\.mode) == [.remove])
        #expect(readable.set.items.first?.keepParent == true)

        let restricted = F.classify([.restricted(".Trash")])
        #expect(restricted.set.trashBytes == nil)
        #expect(restricted.set.items.isEmpty)
    }

    // MARK: Links and ids

    /// Bug caught: reclaim double-count or phantom bytes: an item must list the link groups it holds a link of.
    @Test func linkGroupIndices() {
        let result = F.classify([
            T.dir("Library", [T.dir("Caches", [
                F.aged("com.foo.cache", days: 1, [T.link("shared", ino: 7, bytes: 5000)]),
                F.aged("com.bar.cache", days: 1),
            ])]),
            T.dir("Documents", [T.link("other-link", ino: 7, bytes: 5000)]),
        ])
        let byName = Dictionary(uniqueKeysWithValues: result.set.items.map { ($0.name, $0.linkGroupIndices) })
        #expect(byName == ["com.foo.cache": [0], "com.bar.cache": []])
    }

    /// Bug caught: unstable ids across runs (selection / overlay keyed by id would drift).
    @Test func idsAreSequentialByCategoryThenPath() {
        let result = F.classify([
            T.dir("Library", [T.dir("Caches", [F.aged("com.b.cache", days: 1), F.aged("com.a.cache", days: 1)])]),
            T.dir(".Trash", [T.file("t", 10)]),
            T.dir("Documents", [T.file("big", 600_000_000, mtime: F.ago(1))]),
        ])
        #expect(result.set.items.map(\.id) == [0, 1, 2, 3])
        #expect(result.set.items.map(\.path) == [
            "/Users/test/Library/Caches/com.a.cache", "/Users/test/Library/Caches/com.b.cache",
            "/Users/test/Documents/big", "/Users/test/.Trash",
        ])
    }
}
