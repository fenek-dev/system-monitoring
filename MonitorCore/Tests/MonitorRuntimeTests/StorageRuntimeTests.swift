import Darwin
import Foundation
import MonitorLive
import MonitorModel
import Synchronization
import Testing
@testable import MonitorDiskTools
@testable import MonitorRuntime

private struct NoGit: GitTracking {
    func hasTrackedFiles(project: String, dir: String) -> Bool { true }
}

private struct NoDevTools: DevToolProbe {
    var xcodeSelectOK: Bool { false }
    func unavailableSimulatorUDIDs() -> [String] { [] }
}

private struct NoProcesses: ProcessPathSource {
    func snapshot() -> HeldPaths { HeldPaths(paths: []) }
}

private let fixtureID = "com.example.storage-fixture"

/// Temp home + data directory (real paths: `/var` vs `/private/var` would break path comparisons).
private struct Dirs {
    let root: String
    var home: String { root + "/home" }
    var data: URL { URL(fileURLWithPath: root + "/data") }

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("storage-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made.appendingPathComponent("home"), withIntermediateDirectories: true)
        root = made.resolvingSymlinksInPath().path
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    var fixture: String { home + "/Library/Caches/" + fixtureID }
}

private func environment(_ dirs: Dirs, platform: StoragePlatform = .none) -> StorageEngine.Environment {
    var env = StorageEngine.Environment.live(home: dirs.home, dataDirectory: dirs.data, platform: platform)
    env.scanAccess = { ScanAccessPolicy(fullDiskAccess: true) }
    env.classifier = Classifier(home: dirs.home, dataDirectories: [dirs.data.path], git: NoGit(), devTools: NoDevTools(),
                                isUbiquitous: { _ in false })
    env.installedApps = { InstalledAppSet(ids: [fixtureID: OwnerApp(bundleID: fixtureID, name: "Fixture")]) }
    env.lastUsed = { _, _ in [:] }
    env.processes = NoProcesses()
    return env
}

/// Scan of an in-memory home holding only the fixture cache: no filesystem under the home is touched.
private func inMemoryEnvironment(_ dirs: Dirs, platform: StoragePlatform = .none,
                                 onList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in })
    -> StorageEngine.Environment {
    var env = environment(dirs, platform: platform)
    let tree: [InMemoryLister.Item] = [
        .dir("Library", [.dir("Caches", [.dir(fixtureID, [.file("blob", 4_000_000)])])]),
    ]
    env.scanner = { [home = dirs.home] _, access in
        Scanner(lister: InMemoryLister(tree, onList: onList), threads: 2, home: home, access: access)
    }
    env.sizer = { _ in PrivateSizer(lister: InMemoryLister(tree), rootPath: dirs.home) }
    env.volumeUUID = { _ in nil }
    return env
}

private let options = ClassifyOptions(now: Date(timeIntervalSince1970: 1_800_000_000))

private func collect(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
    var events: [ScanEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func classified(_ events: [ScanEvent]) -> [CleanupSet] {
    events.compactMap { if case let .classified(set) = $0 { set } else { nil } }
}

@Suite("StorageRuntime")
struct StorageRuntimeTests {
    /// Bug: the pipeline drops cleaner events, the fixture is silently excluded, or the sidebar summary / overlay
    /// sidecar keep showing the cleaned item.
    @MainActor @Test func cleanRemovesFixtureAndPersistsOverlayAndSummary() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        try FileManager.default.createDirectory(atPath: dirs.fixture, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: URL(fileURLWithPath: dirs.fixture + "/blob"))

        let engine = StorageEngine(environment(dirs))
        let pipeline = StoragePipeline(engine: engine, dataDirectory: dirs.data)
        let actions = pipeline.actions
        let events = await collect(actions.scan(.home(dirs.home), options))
        let final = try #require(classified(events).last)
        let item = try #require(final.items.first { $0.path == dirs.fixture })
        #expect(item.category == .userCaches)
        #expect(item.tier == .safe)
        #expect(!item.runningApp)
        let before = try #require(await actions.loadSummary())
        #expect((before.reclaimableBytes ?? 0) >= item.allocBytes)

        var report: CleanReport?
        for await event in actions.clean([item]) {
            if case let .finished(finished) = event { report = finished }
        }
        let finished = try #require(report)
        #expect(finished.freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: dirs.fixture + "/blob"))

        let root = ScanRoot.home(dirs.home)
        let cache = ScanCache(directory: dirs.data)
        let (tree, overlay) = try #require(cache.load(root: root, volumeUUID: StorageEngine.Environment.volumeUUID(root)))
        let node = try #require(tree.lookup(path: dirs.fixture))
        // Cache directories keep their folder: the node survives, emptied.
        #expect(try overlay.size(node, in: tree) == 0)
        #expect(try overlay.size(node, in: tree) != tree.allocBytes[Int(node)])

        var afterSet = final
        afterSet.items.removeAll { $0.id == item.id }
        let expected = try StorageCleanMath.reclaimable(set: afterSet, tree: tree, overlay: overlay)
        let after = try #require(await actions.loadSummary())
        #expect(after.reclaimableBytes == expected.bytes)
        #expect(after.reclaimableBytes != before.reclaimableBytes)
    }

    /// Bug: a cancelled (partial) scan is cached and loaded as truth on the next launch.
    @MainActor @Test func cancelledScanFailsAndLeavesNoCache() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        let engine = StorageEngine(inMemoryEnvironment(dirs, onList: { path throws(ListError) in
            guard path == "Library" else { return }
            startedSignal.yield()
            gate.wait()
        }))
        let stream = engine.scan(root: .home(dirs.home), options: options)
        let collecting = Task { await collect(stream) }
        for await _ in started { break }
        engine.cancelScan()
        gate.signal()
        let events = await collecting.value
        guard case .failed(.cancelled)? = events.last else {
            Issue.record("last event is not .failed(.cancelled): \(events.count) events")
            return
        }
        #expect(!events.contains { if case .finished = $0 { true } else { false } })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dirs.data.path)) ?? []
        #expect(!files.contains { $0.hasPrefix("storage-scan-") })
    }

    /// Bug: a classification still running when the window closes delivers results and resurrects the tree.
    @MainActor @Test func releaseDropsLateClassification() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        var env = inMemoryEnvironment(dirs)
        env.installedApps = {
            reachedSignal.yield()
            gate.wait()
            return InstalledAppSet(ids: [:])
        }
        let engine = StorageEngine(env)
        let stream = engine.scan(root: .home(dirs.home), options: options)
        let collecting = Task { await collect(stream) }
        for await _ in reached { break }
        engine.release()
        gate.signal()
        let events = await collecting.value
        #expect(classified(events).isEmpty)
        #expect(engine.current() == nil)
    }

    /// Bug: pre-checked caches of a running app (its files are in use): the badge is missing in one of the paths
    /// that produce a classification.
    @MainActor @Test func runningOwnerIsFlaggedInScanCachedAndReclassify() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let platform = StoragePlatform(runningBundleIDs: { [fixtureID] })
        let engine = StorageEngine(inMemoryEnvironment(dirs, platform: platform))
        let events = await collect(engine.scan(root: .home(dirs.home), options: options))
        let scanned = try #require(classified(events).last)
        #expect(scanned.items.map(\.runningApp) == [true])

        engine.release()
        let cached = try #require(await engine.loadCached(root: .home(dirs.home), options: options))
        #expect(cached.2.items.map(\.runningApp) == [true])
        let again = try #require(await engine.reclassify(options: options))
        #expect(again.items.map(\.runningApp) == [true])
        #expect(again.privateSizesFinal)
    }
}
