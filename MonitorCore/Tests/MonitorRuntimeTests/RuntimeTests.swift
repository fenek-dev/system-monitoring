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

@MainActor @Suite(.serialized) struct RuntimeTests {
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

    @Test func shutdownLeavesTheMainActorFree() async throws {
        // A MainActor timer must keep firing while shutdown awaits the store (TerminationController's 3 s timeout).
        let h = try RuntimeHarness()
        h.pipeline.start()
        #expect(await h.log.wait(atLeast: 3))
        let beats = OSAllocatedUnfairLock(initialState: 0)
        let heart = Task { @MainActor in
            while !Task.isCancelled {
                beats.withLock { $0 += 1 }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await h.pipeline.shutdown()
        heart.cancel()
        #expect(beats.withLock { $0 } > 0)
    }

    @Test func fileStoreSurvivesRelaunchAndBadDirFallsBackToMemory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, persistent) = LivePipeline.openStore(in: dir)
        #expect(persistent && store != nil)
        try await store?.shutdown()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.sqlite").path))

        let (fallback, ok) = LivePipeline.openStore(in: URL(fileURLWithPath: "/dev/null/telltale"))
        #expect(!ok && fallback != nil)                          // in-memory: History still works this launch
        try await fallback?.shutdown()
    }
}
