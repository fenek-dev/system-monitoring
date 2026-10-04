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
                                 tree: [InMemoryLister.Item] = [
                                     .dir("Library", [.dir("Caches", [.dir(fixtureID, [.file("blob", 4_000_000)])])]),
                                 ],
                                 onList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in },
                                 sizerOnList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in })
    -> StorageEngine.Environment {
    var env = environment(dirs, platform: platform)
    env.scanner = { [home = dirs.home] _, access in
        Scanner(lister: InMemoryLister(tree, onList: onList), threads: 2, home: home, access: access)
    }
    env.sizer = { _ in PrivateSizer(lister: InMemoryLister(tree, onList: sizerOnList), rootPath: dirs.home) }
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

    /// Bug: ejecting a volume mid-scan never reaches the scanner (the platform signal is not wired into the scan).
    @MainActor @Test func willUnmountFailsTheScanAsVolumeRemoved() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let (unmounts, unmount) = AsyncStream.makeStream(of: String.self)
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        let platform = StoragePlatform(willUnmount: { unmounts })
        let engine = StorageEngine(inMemoryEnvironment(dirs, platform: platform, onList: { path throws(ListError) in
            guard path == "Library" else { return }
            startedSignal.yield()
            gate.wait()
        }))
        let collecting = Task { await collect(engine.scan(root: .home(dirs.home), options: options)) }
        for await _ in started { break }
        unmount.yield(dirs.home)
        // The failure ends the stream while the listing is still blocked: no waiting for the gate.
        let events = await collecting.value
        gate.signal()
        guard case .failed(.volumeRemoved)? = events.last else {
            Issue.record("last event is not .failed(.volumeRemoved)")
            return
        }
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

// MARK: - Races (review round 1)

private let leftoverID = "com.unknown.gone"
private let leftoverTree: [InMemoryLister.Item] = [
    .dir("Library", [
        .dir("Caches", [.dir(fixtureID, [.file("blob", 4_000_000)])]),
        .dir("Application Support", [.dir(leftoverID, [.file("data", 2_000_000)])]),
    ]),
]

/// Moves into `directory` like `FakeTrash` (W2c tests), optionally holding the call until the test releases it.
private final class GatedTrash: TrashMover {
    let directory: String
    let reached: AsyncStream<Void>.Continuation?
    let gate: DispatchSemaphore?

    init(directory: String, reached: AsyncStream<Void>.Continuation? = nil, gate: DispatchSemaphore? = nil) {
        self.directory = directory
        self.reached = reached
        self.gate = gate
    }

    func trash(path: String) throws(TrashError) -> String {
        reached?.yield()
        gate?.wait()
        let destination = directory + "/" + (path as NSString).lastPathComponent
        guard rename(path, destination) == 0 else { throw .failed("errno \(errno)") }
        return destination
    }
}

private final class CountingDeleter: Deleter {
    let deleted = Mutex(0)
    let cancelled = Mutex(0)
    func delete(_ target: DeleteTarget, clearImmutable: Bool) -> DeleteOutcome {
        deleted.withLock { $0 += 1 }
        return DeleteOutcome(removed: true)
    }
    func cancelInFlight() { cancelled.withLock { $0 += 1 } }
}

private func trashItem(for path: String, in tree: StorageTree) throws -> CleanupItem {
    let node = try #require(tree.lookup(path: path))
    return CleanupItem(id: 900, nodeID: node, path: path, name: (path as NSString).lastPathComponent,
                       category: .largeOld, tier: .review, mode: .trash, identity: nil,
                       allocBytes: tree.allocBytes[Int(node)])
}

private func makeStuff(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data(count: 200_000).write(to: URL(fileURLWithPath: path + "/data"))
}

@Suite("StorageRuntimeRaces")
struct StorageRuntimeRaceTests {
    /// Bug (P1): a cancel that arrives after the run was requested but before it started is lost, so the
    /// cancelled clean still deletes everything.
    @MainActor @Test func cancelBeforeTheRunStartsRefusesIt() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        try FileManager.default.createDirectory(atPath: dirs.fixture, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: URL(fileURLWithPath: dirs.fixture + "/blob"))
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        var env = environment(dirs)
        env.beforeCleanRegistration = {
            reachedSignal.yield()
            gate.wait()
        }
        let engine = StorageEngine(env)
        let events = await collect(engine.scan(root: .home(dirs.home), options: options))
        let item = try #require(classified(events).last?.items.first { $0.path == dirs.fixture })

        let stream = engine.clean([item])
        let collecting = Task { () -> CleanReport? in
            var report: CleanReport?
            for await event in stream { if case let .finished(done) = event { report = done } }
            return report
        }
        for await _ in reached { break }
        engine.cancelClean()
        gate.signal()
        let report = try #require(await collecting.value)
        #expect(report.cancelled)
        #expect(report.outcomes.map(\.skip) == [.cancelled])
        #expect(FileManager.default.fileExists(atPath: dirs.fixture + "/blob"))
    }

    /// Bug (P2): closing the window mid-clean drops the run's outcomes (no sidecar), so the next launch shows the
    /// cleaned item again.
    @MainActor @Test func closeMidCleanStillPersistsThatScansSidecar() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let stuff = dirs.home + "/stuff"
        try makeStuff(stuff)
        let fakeTrash = dirs.root + "/fakeTrash"
        try FileManager.default.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        var env = environment(dirs)
        env.trash = GatedTrash(directory: fakeTrash, reached: reachedSignal, gate: gate)
        let engine = StorageEngine(env)
        let pipeline = StoragePipeline(engine: engine, dataDirectory: dirs.data)
        let actions = pipeline.actions
        _ = await collect(actions.scan(.home(dirs.home), options))
        let tree = try #require(engine.current()?.tree)
        let item = try trashItem(for: stuff, in: tree)

        let stream = actions.clean([item])
        let collecting = Task { for await _ in stream {} }
        for await _ in reached { break }
        actions.release()
        gate.signal()
        await collecting.value

        let root = ScanRoot.home(dirs.home)
        let loaded = try #require(ScanCache(directory: dirs.data)
            .load(root: root, volumeUUID: StorageEngine.Environment.volumeUUID(root)))
        let node = try #require(loaded.tree.lookup(path: stuff))
        #expect(try loaded.overlay.isRemoved(node, in: loaded.tree))
    }

    /// Bug (P2): a clean that outlives the window applies its outcomes to a tree opened later (same node ids).
    @MainActor @Test func oldRunNeverTouchesTheRescannedTree() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let stuff = dirs.home + "/stuff"
        try makeStuff(stuff)
        let fakeTrash = dirs.root + "/fakeTrash"
        try FileManager.default.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        var env = environment(dirs)
        env.trash = GatedTrash(directory: fakeTrash, reached: reachedSignal, gate: gate)
        let engine = StorageEngine(env)
        let pipeline = StoragePipeline(engine: engine, dataDirectory: dirs.data)
        let actions = pipeline.actions
        _ = await collect(actions.scan(.home(dirs.home), options))
        let item = try trashItem(for: stuff, in: try #require(engine.current()?.tree))

        let stream = actions.clean([item])
        let collecting = Task { for await _ in stream {} }
        for await _ in reached { break }
        actions.release()
        _ = await collect(actions.scan(.home(dirs.home), options))
        gate.signal()
        await collecting.value

        let current = try #require(engine.current())
        let node = try #require(current.tree.lookup(path: stuff))
        #expect(try !current.overlay.isRemoved(node, in: current.tree))
        let root = ScanRoot.home(dirs.home)
        let loaded = try #require(ScanCache(directory: dirs.data)
            .load(root: root, volumeUUID: StorageEngine.Environment.volumeUUID(root)))
        #expect(try !loaded.overlay.isRemoved(try #require(loaded.tree.lookup(path: stuff)), in: loaded.tree))
    }

    /// Bug (P2): the summary keeps counting a cleaned item after a reclassification (the classifier output predates
    /// the clean and the folder is only emptied, not removed).
    @MainActor @Test func summaryStaysCleanedAfterReclassify() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        try FileManager.default.createDirectory(atPath: dirs.fixture, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: URL(fileURLWithPath: dirs.fixture + "/blob"))
        let engine = StorageEngine(environment(dirs))
        let pipeline = StoragePipeline(engine: engine, dataDirectory: dirs.data)
        let actions = pipeline.actions
        let events = await collect(actions.scan(.home(dirs.home), options))
        let item = try #require(classified(events).last?.items.first { $0.path == dirs.fixture })
        let before = try #require(await actions.loadSummary())
        for await _ in actions.clean([item]) {}
        _ = await actions.reclassify(options)
        let after = try #require(await actions.loadSummary())
        #expect((before.reclaimableBytes ?? 0) > 0)
        #expect(after.reclaimableBytes == 0)
    }

    /// Bug (P2): an undo of a Space Map trash outside home is refused (or would be allowed anywhere under home):
    /// the record must be restored under the root that trashed it.
    @MainActor @Test func undoRestoresUnderTheRootThatTrashed() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let external = dirs.root + "/external"
        let doomed = external + "/doomed"
        try makeStuff(doomed)
        let fakeTrash = dirs.root + "/fakeTrash"
        try FileManager.default.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
        var env = environment(dirs)
        env.trash = GatedTrash(directory: fakeTrash)
        let engine = StorageEngine(env)
        _ = await collect(engine.scan(root: .folder(external), options: options))
        let item = try trashItem(for: doomed, in: try #require(engine.current()?.tree))

        var record: UndoRecord?
        for await event in engine.clean([item]) { if case let .finished(report) = event { record = report.undo } }
        let undoRecord = try #require(record)
        #expect(!FileManager.default.fileExists(atPath: doomed))

        var restored: [String] = []
        for await event in engine.undo(undoRecord) { if case let .restored(_, path) = event { restored.append(path) } }
        #expect(restored == [doomed])
        #expect(FileManager.default.fileExists(atPath: doomed + "/data"))
    }

    /// Bug (P2): two cache loads (root change, reopened window) share a generation: the earlier, slower one
    /// publishes its tree after the later one.
    @MainActor @Test func laterCacheLoadWinsOverASlowerEarlierOne() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gateStream, gateSignal) = AsyncStream.makeStream(of: Void.self)
        let armed = Mutex(false)
        let platform = StoragePlatform(appPaths: { _ in
            if armed.withLock({ $0 }) {
                reachedSignal.yield()
                for await _ in gateStream { break }
            }
            return []
        })
        let engine = StorageEngine(inMemoryEnvironment(dirs, platform: platform, tree: leftoverTree))
        let other = ScanRoot.folder(dirs.root + "/other")
        _ = await collect(engine.scan(root: .home(dirs.home), options: options))
        _ = await collect(engine.scan(root: other, options: options))

        armed.withLock { $0 = true }
        let slow = Task { await engine.loadCached(root: .home(dirs.home), options: options) }
        for await _ in reached { break }
        let later = await engine.loadCached(root: other, options: options)
        #expect(later != nil)
        gateSignal.yield()
        #expect(await slow.value == nil)
        #expect(engine.current()?.root == other)
    }

    /// Bug (P2): the first classification waits for the owner lookups, so the map's items appear only after them.
    @MainActor @Test func firstClassificationArrivesBeforeOwnerLookups() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let (sawFirst, sawFirstSignal) = AsyncStream.makeStream(of: Void.self)
        let arrivedFirst = Mutex<Bool?>(nil)
        let platform = StoragePlatform(appPaths: { _ in
            // Passes only when the consumer has already seen a classification; the timer ends the wait on failure.
            let timer = Task {
                try? await Task.sleep(for: .seconds(3))
                sawFirstSignal.finish()
            }
            var got = false
            for await _ in sawFirst { got = true; break }
            timer.cancel()
            arrivedFirst.withLock { $0 = got }
            return []
        })
        let engine = StorageEngine(inMemoryEnvironment(dirs, platform: platform, tree: leftoverTree))
        var seen = 0
        for await event in engine.scan(root: .home(dirs.home), options: options) {
            if case .classified = event {
                seen += 1
                if seen == 1 { sawFirstSignal.yield() }
            }
        }
        #expect(arrivedFirst.withLock { $0 } == true)
    }

    /// Bug (P2): an app launched while the private-size pass ran still shows as not running in the final set.
    @MainActor @Test func runningAppIsRefreshedBeforeFinalPublication() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let running = Mutex(Set<String>())
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        let platform = StoragePlatform(runningBundleIDs: { running.withLock { $0 } })
        let engine = StorageEngine(inMemoryEnvironment(dirs, platform: platform, sizerOnList: { path throws(ListError) in
            guard path.hasSuffix(fixtureID) else { return }
            reachedSignal.yield()
            gate.wait()
        }))
        let collecting = Task { await collect(engine.scan(root: .home(dirs.home), options: options)) }
        for await _ in reached { break }
        running.withLock { $0 = [fixtureID] }
        gate.signal()
        let sets = classified(await collecting.value)
        #expect(sets.first?.items.map(\.runningApp) == [false])
        #expect(sets.last?.items.map(\.runningApp) == [true])
        #expect(sets.last?.privateSizesFinal == true)
    }

    /// Bug (P2): quitting while the launch sweep has not started (or is running) leaves the deleter running.
    @MainActor @Test func quitDuringLaunchStopsTheSweep() async throws {
        func engine(_ dirs: Dirs, deleter: CountingDeleter, gate: DispatchSemaphore?,
                    reached: AsyncStream<Void>.Continuation?) throws -> StorageEngine {
            let commit = dirs.data.appendingPathComponent("staging/commit/entry")
            try FileManager.default.createDirectory(at: commit, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dirs.data.appendingPathComponent("staging/pending"),
                                                    withIntermediateDirectories: true)
            var env = environment(dirs)
            env.deleter = { _ in
                reached?.yield()
                gate?.wait()
                return deleter
            }
            return StorageEngine(env)
        }
        // Control: without a quit the sweep deletes the planted entry.
        let control = try Dirs()
        defer { control.remove() }
        let controlDeleter = CountingDeleter()
        await (try engine(control, deleter: controlDeleter, gate: nil, reached: nil)).awaitLaunch()
        #expect(controlDeleter.deleted.withLock { $0 } == 1)

        let dirs = try Dirs()
        defer { dirs.remove() }
        let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
        let gate = DispatchSemaphore(value: 0)
        let counting = CountingDeleter()
        let quitting = try engine(dirs, deleter: counting, gate: gate, reached: reachedSignal)
        for await _ in reached { break }
        quitting.abortDeletes()
        gate.signal()
        await quitting.awaitLaunch()
        #expect(counting.deleted.withLock { $0 } == 0)
        #expect(counting.cancelled.withLock { $0 } >= 1)
    }
}
