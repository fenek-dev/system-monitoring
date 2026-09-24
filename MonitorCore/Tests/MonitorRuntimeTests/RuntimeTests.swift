import Foundation
import MonitorLive
import MonitorModel
import os
import Testing
@testable import MonitorEngine
@testable import MonitorRuntime
@testable import MonitorStore

/// Ticks taken by the engine, seen from the test (the sensor itself never leaves the engine actor).
final class TickLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [SamplingMode]())
    func add(_ m: SamplingMode) { state.withLock { $0.append(m) } }
    var modes: [SamplingMode] { state.withLock { $0 } }
    var count: Int { modes.count }

    func wait(atLeast n: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while count < n, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return count >= n
    }
}

/// Host CPU ticks that advance 1 s of busy/idle work per call, so frames get rates; logs every call.
final class CountingCPUSensor: Sensor {
    typealias Reading = HostCPUReading
    let id = SensorID.hostCPU
    let cadence = SensorCadence.everyTick
    private let log: TickLog
    private var n: UInt64 = 0
    init(_ log: TickLog) { self.log = log }
    func prepare() throws(SensorError) {}
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: HostCPUReading, capturedNs: UInt64) {
        n += 1
        log.add(ctx.mode)
        let core = CoreTicks(user: n * 30, system: n * 10, idle: n * 60)
        return (HostCPUReading(cores: [core, core], coreKinds: [.performance, .efficiency]), ctx.uptimeNs)
    }
    func invalidate() {}
}

@MainActor
struct RuntimeHarness {
    let log = TickLog()
    let store: HistoryStore
    let pipeline: LivePipeline

    /// flushInterval 1 h: nothing reaches SQLite before shutdown unless the test flushes.
    init(background: Duration = .milliseconds(20), interactive: Duration = .milliseconds(10)) throws {
        let log = self.log
        let factory = SensorFactory { _ in
            SensorSuite(
                processes: FixtureSensor(.processes, readings: [.success(ProcessTableReading(processes: [
                    RawProcess(id: ProcessID(pid: 10, startTimeUs: 1), uid: 501, comm: "a", name: "a", path: "/usr/bin/a",
                               cpuTimeNs: 0),
                ]))]),
                hostCPU: CountingCPUSensor(log),
                memory: FixtureSensor(.memory, readings: [.success(MemoryReading())]))
        }
        let engine = SamplingEngine(factory: factory, canary: .none,
                                    resolver: { BundleAppResolver(currentUID: 501, readInfoPlist: { _ in nil }) },
                                    interactiveInterval: interactive, backgroundInterval: background)
        store = try HistoryStore(location: .inMemory,
                                 config: StoreConfig(flushInterval: .seconds(3_600), flushMaxRecords: 100_000,
                                                     maintenanceInterval: .zero))
        pipeline = LivePipeline(engine: engine, store: store)
    }

    func rows() async throws -> Int {
        try await store.intValue("SELECT COUNT(*) FROM system_raw") ?? -1
    }

    func events(_ kind: String) async throws -> Int {
        try await store.intValue("SELECT COUNT(*) FROM event WHERE kind = '\(kind)'") ?? -1
    }
}

/// `.idleMainActor`: pipeline commands and frames hop through the main actor, and the harness waits a bounded time
/// for ticks; inside the initial main-queue backlog of a full run (other targets' renders) those waits time out.
@MainActor @Suite(.serialized, .idleMainActor) struct RuntimeTests {
    @Test func tenTicksWriteTenRowsAndShutdownFlushes() async throws {
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 10))
        await h.store.writesSettled()
        #expect(try await h.rows() == 0)                         // still buffered: flush interval is 1 h
        await h.pipeline.shutdown()
        let ticks = h.log.count
        #expect(ticks >= 10)
        #expect(try await h.rows() == ticks)                     // one row per tick, all flushed by shutdown
    }

    @Test func framesReachTheLiveModel() async throws {
        let h = try RuntimeHarness()
        h.pipeline.live.isPresenting = true                      // the app sets it with the visibility
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 5))
        let deadline = ContinuousClock.now + .seconds(2)
        while h.pipeline.live.phase != .live, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(h.pipeline.live.phase == .live)
        #expect(h.pipeline.live.cpu.usage != nil)
        #expect(h.pipeline.live.apps.contains { $0.identity.displayName == "a" })
        await h.pipeline.shutdown()
    }

    @Test func pauseTakesNoSamplesAndWritesNoRows() async throws {
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 3))
        h.pipeline.setPaused(true)
        #expect(h.pipeline.live.alert.paused)
        try await Task.sleep(for: .milliseconds(100))            // the pause command reached the engine
        let atPause = h.log.count
        try await Task.sleep(for: .milliseconds(300))            // ≥ 15 background intervals
        #expect(h.log.count == atPause)
        if case .paused = h.pipeline.live.phase {} else { Issue.record("phase \(h.pipeline.live.phase)") }
        await h.pipeline.shutdown()
        #expect(try await h.rows() == atPause)
        #expect(try await h.events("samplingPaused") == 1)
    }

    @Test func resumeSamplesAgain() async throws {
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 2))
        h.pipeline.setPaused(true)
        try await Task.sleep(for: .milliseconds(80))
        let atPause = h.log.count
        h.pipeline.setPaused(false)
        #expect(await h.log.wait(atLeast: atPause + 3))
        #expect(!h.pipeline.live.alert.paused)
        await h.pipeline.shutdown()
        #expect(try await h.rows() == h.log.count)
    }

    @Test func visibilityCommandsReachTheEngineInOrder() async throws {
        let h = try RuntimeHarness(background: .seconds(3_600), interactive: .milliseconds(10))
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 1))                    // the start tick (background)
        h.pipeline.setVisibility(UIVisibility(popoverOpen: true))
        h.pipeline.setVisibility(UIVisibility())
        h.pipeline.setVisibility(UIVisibility(dashboardVisible: true, page: .cpu))
        #expect(await h.log.wait(atLeast: 6))
        #expect(h.log.modes.first == .background)
        #expect(h.log.modes.suffix(3).allSatisfy { $0 == .interactive })   // last command wins: interactive
        await h.pipeline.shutdown()
    }

    /// N4: a store open slower than the 3 s termination timeout must not keep crash-canary markers set — shutdown
    /// stops the engine (invalidate → disarm) before it awaits the store.
    @Test func shutdownClearsCanaryBeforeAwaitingASlowStoreOpen() async throws {
        let suite = "dev.telltale.tests.canary-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let canary = TelltaleRuntime.canary(suite: suite)
        let factory = SensorFactory { _ in
            // Warming (off-queue setup still running): the marker stays armed between calls.
            SensorSuite(smc: FixtureSensor(.smc, readings: [.failure(.transient("warming up"))],
                                           cadence: .every(.seconds(60), background: .seconds(60))))
        }
        let engine = SamplingEngine(factory: factory, canary: canary,
                                    resolver: { BundleAppResolver(currentUID: 501, readInfoPlist: { _ in nil }) },
                                    interactiveInterval: .milliseconds(10), backgroundInterval: .milliseconds(20))
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let opening = Task<LivePipeline.OpenedStore, Never> {
            for await _ in gate {}                                        // migration that takes "forever"
            return LivePipeline.OpenedStore(store: nil, persistent: false)
        }
        let pipeline = LivePipeline(engine: engine, opening: opening)
        pipeline.start()
        let armedBy = ContinuousClock.now + .seconds(5)
        while !canary.isTripped(.smc), ContinuousClock.now < armedBy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(canary.isTripped(.smc))
        let shutdown = Task { await pipeline.shutdown() }
        let clearedBy = ContinuousClock.now + .seconds(2)
        while canary.isTripped(.smc), ContinuousClock.now < clearedBy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!canary.isTripped(.smc), "marker still set while the store is opening")
        open.finish()
        await shutdown.value
    }

    @Test func shutdownIsIdempotentAndSafeBeforeStart() async throws {
        let idle = try RuntimeHarness()
        await idle.pipeline.shutdown()
        await idle.pipeline.shutdown()
        #expect(try await idle.rows() == 0)
        idle.pipeline.start()                                    // no-op after shutdown
        try await Task.sleep(for: .milliseconds(60))
        #expect(idle.log.count == 0)

        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 2))
        await h.pipeline.shutdown()
        let n = h.log.count
        await h.pipeline.shutdown()
        h.pipeline.setPaused(true)                               // ignored after shutdown
        #expect(try await h.rows() == n)
    }

    /// `n` buffered one-app records, 1 s apart (unique `ts`), so the shutdown flush has real work.
    /// Pass `base: Date()` for a store with maintenance on: raw rows older than `rawRetention` (24 h) are deleted.
    static func buffer(_ n: Int, into store: HistoryStore,
                       base: Date = Date(timeIntervalSince1970: 1_790_000_000)) async {
        let app = AppRecord(identity: AppIdentity(key: AppKey(kind: .process, id: "/usr/bin/a"), displayName: "a"))
        for i in 0..<n {
            await store.append(RecordBatch(record: HistoryRecord(time: base.addingTimeInterval(Double(i)),
                                                                 interval: .seconds(1), apps: [app])))
        }
    }

    @Test func shutdownLeavesTheMainActorFree() async throws {
        // MainActor timers must keep firing while shutdown awaits a slow store flush (TerminationController's
        // 3 s timeout runs on the MainActor).
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 3))
        await Self.buffer(40_000, into: h.store)
        let gaps = OSAllocatedUnfairLock(initialState: (last: ContinuousClock.now, max: Duration.zero, beats: 0))
        let heart = Task { @MainActor in
            while !Task.isCancelled {
                let now = ContinuousClock.now
                gaps.withLock { $0 = (now, max($0.max, now - $0.last), $0.beats + 1) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await Task.yield()
        let t0 = ContinuousClock.now
        await h.pipeline.shutdown()
        let took = ContinuousClock.now - t0
        heart.cancel()
        let g = gaps.withLock { $0 }
        #expect(took > .milliseconds(100), "flush too fast to prove anything: \(took)")
        #expect(g.beats > 10)
        #expect(g.max < .milliseconds(50), "MainActor blocked \(g.max) during a \(took) shutdown")
        #expect(try await h.rows() == h.log.count + 40_000)
    }

    @Test func concurrentShutdownsBothWaitForTheFlush() async throws {
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 2))
        await Self.buffer(20_000, into: h.store)
        let p = h.pipeline
        async let first: Void = p.shutdown()
        async let second: Void = p.shutdown()
        _ = await (first, second)
        #expect(try await h.rows() == h.log.count + 20_000)
        // A late third call also returns only after the (finished) flush.
        await p.shutdown()
    }

    @Test func secondShutdownReturnsOnlyAfterTheFirstFlushed() async throws {
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 2))
        await Self.buffer(20_000, into: h.store)
        let p = h.pipeline
        let first = Task { @MainActor in await p.shutdown() }
        await Task.yield()                                        // first shutdown is under way
        await p.shutdown()                                        // must not return before the flush
        await h.store.writesSettled()
        #expect(await h.store.pendingRecordCount == 0)
        #expect(try await h.rows() == h.log.count + 20_000)
        await first.value
    }

    @Test func fileStoreSurvivesRelaunchAndBadDirFallsBackToMemory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, persistent) = LivePipeline.openStore(in: dir)
        #expect(persistent && store != nil)
        // Recent timestamps: `openStore` uses the default config, whose maintenance pass at open (racing the appends
        // here and the count below) drops raw rows older than 24 h; a fixed past date made the count flaky.
        if let store { await Self.buffer(25, into: store, base: Date()) }
        try await store?.shutdown()

        let (reopened, again) = LivePipeline.openStore(in: dir)   // relaunch
        #expect(again)
        #expect(try await reopened?.intValue("SELECT COUNT(*) FROM system_raw") == 25)
        try await reopened?.shutdown()

        let (fallback, ok) = LivePipeline.openStore(in: URL(fileURLWithPath: "/dev/null/telltale"))
        #expect(!ok && fallback != nil)                          // in-memory: History still works this launch
        #expect(await fallback?.config.rawRetention == .seconds(3_600))   // with short retention (R-I3)
        #expect(await fallback?.config.rollupThresholds == LivePipeline.rollupThresholds)
        try await fallback?.shutdown()
    }

    /// R-M4: the store opens (WAL, migration, closing orphaned events) off the MainActor. Another connection holds
    /// the write lock that the orphan close needs: the pipeline is built at once, and queries wait for the open.
    @Test func storeOpensOffTheMainActor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (previous, _) = LivePipeline.openStore(in: dir)
        let other = try #require(previous)
        let start = Date(timeIntervalSinceNow: -30)
        await Self.buffer(3, into: other, base: start)
        await other.append(RecordBatch(events: [HistoryEvent(kind: .thermalPressure, start: start, level: .elevated)]))
        try await other.flush()                                 // left open: the previous run "crashed"
        let locked = OSAllocatedUnfairLock(initialState: false)
        let holder = Task { try await other.holdWriteLock(seconds: 0.6) { locked.withLock { $0 = true } } }
        while !locked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }

        let t0 = ContinuousClock.now
        let pipeline = LivePipeline(dataDirectory: dir, disabledSensors: Set(SensorID.allCases), crashSensor: nil)
        #expect(ContinuousClock.now - t0 < .milliseconds(300))   // the open waits ~0.6 s, not the main actor
        let events = try await pipeline.history.events(in: DateInterval(start: start - 60, duration: 3_600))
        #expect(ContinuousClock.now - t0 >= .milliseconds(400))
        let end = try #require(events.count == 1 ? events.first?.end : nil)
        #expect(abs(end.timeIntervalSince(start + 2)) < 0.001)   // closed at its last sample (ms storage)
        await pipeline.historyReady()
        #expect(pipeline.historyPersistent)
        try await holder.value
        await pipeline.shutdown()
        try await other.shutdown()
    }

    /// R-M8: the batch opening a system sleep is flushed at once (a Mac that never wakes keeps it).
    @Test func willSleepFlushesTheStore() async throws {
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 3))
        await h.store.writesSettled()
        #expect(try await h.rows() == 0)                         // flush interval is 1 h
        h.pipeline.systemWillSleep()
        let deadline = ContinuousClock.now + .seconds(3)
        while try await h.events("systemSleep") == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await h.events("systemSleep") == 1)
        #expect(try await h.rows() >= 3)
        h.pipeline.systemDidWake()
        await h.pipeline.shutdown()
    }

    @Test func intervalStatsSummarisePerModeWindows() {
        var s = LivePipeline.IntervalStats()
        func frame(_ ms: Int, _ mode: SamplingMode) -> SystemFrame {
            SystemFrame(wallTime: Date(), uptimeNs: 0, interval: .milliseconds(ms), mode: mode)
        }
        for i in 0..<(LivePipeline.IntervalStats.window - 1) { s.add(frame(5_000 + i, .background)) }
        s.add(frame(1_000, .interactive))                           // other mode: separate window
        #expect(s.lastSummary == nil)
        s.add(frame(9_000, .background))                            // 60th background frame → summary
        let sum = s.lastSummary
        #expect(sum?.mode == .background)
        #expect(sum.map { abs($0.median - 5.030) < 0.002 } == true)
        #expect(sum.map { abs($0.max - 9) < 1e-9 } == true)
        #expect(sum.map { $0.p95 >= 5.055 && $0.p95 <= 5.058 } == true)
    }

    @Test func historyPersistentReachesTheFacade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistent = TelltaleRuntime.make(mode: .live, dataDirectory: dir, disabledSensors: Set(SensorID.allCases))
        await persistent.historyReady()
        #expect(persistent.historyPersistent)
        await persistent.shutdown()
        let fallback = TelltaleRuntime.make(mode: .live, dataDirectory: URL(fileURLWithPath: "/dev/null/telltale"),
                                            disabledSensors: Set(SensorID.allCases))
        await fallback.historyReady()
        #expect(!fallback.historyPersistent)
        await fallback.shutdown()
        let mock = TelltaleRuntime.make(mode: .mock(.calm), dataDirectory: dir, disabledSensors: [])
        await mock.historyReady()
        #expect(mock.historyPersistent)
        let h = try RuntimeHarness()
        #expect(h.pipeline.historyPersistent)
        #expect(!LivePipeline(engine: SamplingEngine(factory: SensorFactory { _ in SensorSuite() }), store: h.store,
                              persistent: false).historyPersistent)
    }
}
