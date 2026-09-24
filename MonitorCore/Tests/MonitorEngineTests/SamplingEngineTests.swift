import Foundation
import MonitorModel
import os
import Testing
@testable import MonitorEngine

/// Thread-safe log of the contexts each spy sensor was sampled with.
final class SpyLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[(SensorID, SampleContext)]>(initialState: [])
    func record(_ id: SensorID, _ ctx: SampleContext) { entries.withLock { $0.append((id, ctx)) } }
    func contexts(_ id: SensorID) -> [SampleContext] { entries.withLock { $0.filter { $0.0 == id }.map(\.1) } }
    func count(_ id: SensorID) -> Int { contexts(id).count }
}

/// Returns `make(ctx)` and logs the context.
final class SpySensor<R: Sendable & Codable>: Sensor {
    typealias Reading = R
    let id: SensorID
    let cadence: SensorCadence
    let log: SpyLog
    let delay: useconds_t
    let make: (SampleContext) -> R
    /// Throws `.transient` when true for the tick's context.
    let failsWhen: (SampleContext) -> Bool

    init(_ id: SensorID, cadence: SensorCadence = .everyTick, log: SpyLog, delay: useconds_t = 0,
         failsWhen: @escaping (SampleContext) -> Bool = { _ in false }, make: @escaping (SampleContext) -> R) {
        self.id = id
        self.cadence = cadence
        self.log = log
        self.delay = delay
        self.failsWhen = failsWhen
        self.make = make
    }

    func prepare() throws(SensorError) {}
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        log.record(id, ctx)
        if delay > 0 { usleep(delay) }
        if failsWhen(ctx) { throw .transient("spy failure") }
        return (make(ctx), ctx.uptimeNs)
    }
    func invalidate() {}
}

private func factory(_ log: SpyLog, memoryPressure: MemoryPressureLevel = .normal, tickDelay: useconds_t = 0,
                     processesFailWhen: @escaping @Sendable (SampleContext) -> Bool = { _ in false }) -> SensorFactory {
    SensorFactory { _ in
        SensorSuite(
            processes: SpySensor(.processes, log: log, delay: tickDelay, failsWhen: processesFailWhen) { ctx in
                ProcessTableReading(processes: [own(10, cpuNs: ctx.uptimeNs / 2, energyNJ: ctx.uptimeNs)])
            },
            rootMemory: SpySensor(.rootMemory, cadence: .every(.zero, background: .zero, requires: [.processTable, .memoryAlert]),
                                  log: log) { _ in RootMemoryReading() },
            hostCPU: SpySensor(.hostCPU, log: log) { ctx in
                let t = ctx.uptimeNs / 1_000_000
                return HostCPUReading(cores: [CoreTicks(user: t / 2, idle: t / 2)], coreKinds: [.performance])
            },
            memory: SpySensor(.memory, log: log) { _ in MemoryReading(total: 1 << 34, pressureLevel: memoryPressure) },
            networkFlows: SpySensor(.networkFlows, log: log) { ctx in
                NetworkFlowsReading(flows: [FlowCounter(flowID: 1, process: ProcessID(pid: 10, startTimeUs: 1), proto: .tcp,
                                                        rxBytes: ctx.uptimeNs / 1_000, txBytes: 0)])
            })
    }
}

private func engine(_ log: SpyLog, memoryPressure: MemoryPressureLevel = .normal, tickDelay: useconds_t = 0,
                    interactive: Duration = .milliseconds(20), background: Duration = .milliseconds(60),
                    overlay: Duration = .milliseconds(20)) -> SamplingEngine {
    SamplingEngine(factory: factory(log, memoryPressure: memoryPressure, tickDelay: tickDelay),
                   resolver: { FixtureAppResolver([10: appID("a")]) },
                   interactiveInterval: interactive, backgroundInterval: background, overlayInterval: overlay)
}

/// One long-lived consumer per stream (cancelling an `AsyncStream` iteration would finish the stream).
final class Collector<T: Sendable>: Sendable {
    private let items = OSAllocatedUnfairLock<[T]>(initialState: [])
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(_ stream: AsyncStream<T>) {
        Task { [self] in
            for await x in stream { items.withLock { $0.append(x) } }
            finished.withLock { $0 = true }
        }
    }

    var all: [T] { items.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }

    /// Waits until at least `count` items arrived (or `timeout`); returns everything so far.
    func wait(count: Int, timeout: Duration = .seconds(2)) async -> [T] {
        let deadline = ContinuousClock.now + timeout
        while all.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return all
    }

    func waitFinished(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isFinished, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return isFinished
    }
}

@Suite(.serialized) struct SamplingEngineTests {
    @Test func sampleOnceAssemblesAFrame() async {
        let log = SpyLog()
        let e = engine(log)
        _ = await e.sampleOnce()
        let f = await e.sampleOnce()
        #expect(f.interval != nil)
        #expect(f.processes.first { $0.pid == 10 }?.cpuPercent != nil)
        #expect(f.apps.first?.identity.displayName == "a")
        #expect(f.cpu.usage != nil)
        #expect(f.sensorHealth[.smc] == .unavailable(SensorSuite.notConfigured))
    }

    @Test func sampleOnceRawReturnsTickAndFrame() async {
        let log = SpyLog()
        let e = engine(log)
        let (tick, frame) = await e.sampleOnceRaw()
        guard case .fresh = tick.processes else { Issue.record("processes \(tick.processes)"); return }
        #expect(tick.uptimeNs == frame.uptimeNs)
        #expect(frame.interval == nil)                           // first frame: no rates
    }

    @Test func loopProducesFramesAndRecordsAtTheInteractiveCadence() async {
        let log = SpyLog()
        let e = engine(log)
        let frames = Collector(e.liveFrames), records = Collector(e.records)
        await e.setVisibility(UIVisibility(popoverOpen: true))
        await e.start()
        let got = await frames.wait(count: 4)
        #expect(got.count >= 4)
        #expect(got.allSatisfy { $0.mode == .interactive })
        let batches = await records.wait(count: 3)
        #expect(batches.filter { $0.record != nil }.count >= 3)
        await e.stop()
    }

    @Test func slowTicksDoNotDriftTheCadence() async {
        let log = SpyLog()
        let e = engine(log, tickDelay: 40_000, interactive: .milliseconds(100))   // 40 ms tick, 100 ms interval
        let frames = Collector(e.liveFrames)
        await e.setVisibility(UIVisibility(popoverOpen: true))
        await e.start()
        _ = await frames.wait(count: 9, timeout: .seconds(3))
        await e.stop()
        // bufferingNewest(1) may drop frames for a slow consumer; the sensor log sees every tick
        let starts = log.contexts(.processes).map(\.uptimeNs)
        #expect(starts.count >= 9)
        let n = min(starts.count, 9)
        let mean = Double(starts[n - 1] - starts[0]) / Double(n - 1) / 1e6
        print("PERF cadence mean period \(String(format: "%.1f", mean)) ms (100 ms interval, 40 ms ticks)")
        #expect(abs(mean - 100) <= 5)
    }

    @Test func becomingInteractiveWakesTheSleeper() async {
        let log = SpyLog()
        let e = engine(log, background: .seconds(30))
        let frames = Collector(e.liveFrames)
        await e.start()
        _ = await frames.wait(count: 1)                              // immediate first background sample
        let before = log.count(.processes)
        let start = ContinuousClock.now
        await e.setVisibility(UIVisibility(popoverOpen: true))
        let got = await frames.wait(count: 2, timeout: .seconds(2))
        let latency = ContinuousClock.now - start
        #expect(got.last?.mode == .interactive)
        #expect(log.count(.processes) > before)
        #expect(latency < .milliseconds(50))                          // the 30 s background sleep was cut short
        print("PERF wake-up latency \(latency)")
        await e.stop()
    }

    @Test func becomingOverlayWakesTheSleeper() async {
        let log = SpyLog()
        let e = engine(log, background: .seconds(30))
        let frames = Collector(e.liveFrames)
        await e.start()
        _ = await frames.wait(count: 1)                              // immediate first background sample
        let start = ContinuousClock.now
        await e.setVisibility(UIVisibility(overlayVisible: true))
        let got = await frames.wait(count: 2, timeout: .seconds(2))
        let latency = ContinuousClock.now - start
        #expect(got.last?.mode == .overlay)
        #expect(latency < .milliseconds(50))                          // the 30 s background sleep was cut short
        await e.stop()
    }

    /// Drives `ticks` overlay ticks on a 1-s sample clock (uptime 1000 s + i); returns the frames and, per record,
    /// the tick index (= seconds since the first tick) it was emitted on.
    private func overlayRun(_ log: SpyLog, ticks: Int,
                            processesFailWhen: @escaping @Sendable (SampleContext) -> Bool = { _ in false })
        async -> (frames: [SystemFrame], records: [(tick: Int, record: HistoryRecord)]) {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let e = SamplingEngine(factory: factory(log, processesFailWhen: processesFailWhen),
                               resolver: { FixtureAppResolver([10: appID("a")]) },
                               interactiveInterval: .milliseconds(20), backgroundInterval: .milliseconds(60),
                               uptime: { clock.withLock { $0 } })
        await e.setVisibility(UIVisibility(overlayVisible: true))
        var frames: [SystemFrame] = [], records: [(Int, HistoryRecord)] = []
        for i in 0..<ticks {
            clock.withLock { $0 = Self.base + UInt64(i) * 1_000_000_000 }
            let (frame, batch) = await e.sampleOnceBatch()
            frames.append(frame)
            if let r = batch.record { records.append((i, r)) }
        }
        return (frames, records)
    }

    private static let base: UInt64 = 1_000_000_000_000

    /// R3: in overlay mode only ticks where the process table ran (every 5 s) are recorded, with a 5-s interval.
    @Test func overlayRecordsOnlyFiveSecondTicks() async {
        let log = SpyLog()
        let (frames, records) = await overlayRun(log, ticks: 10)
        #expect(frames.count == 10 && frames.allSatisfy { $0.mode == .overlay })
        #expect(records.map(\.tick) == [0, 5])
        #expect(records.allSatisfy { $0.record.interval == .seconds(5) })
        #expect(log.count(.processes) == 2)
    }

    /// Overlay history does not depend on the process sensor: with it failing, overdue records still land.
    @Test func overlayRecordsWhileProcessesFail() async {
        let (_, records) = await overlayRun(SpyLog(), ticks: 10, processesFailWhen: { _ in true })
        #expect(records.count == 2)
        #expect(records.map(\.record.interval) == [.seconds(5), .seconds(6)])   // overdue: actual gap
    }

    /// A process sensor recovering mid-window never produces two records less than 4.5 s apart.
    @Test func overlayRecordsStaySpacedWhenProcessesRecover() async {
        for failUntil in 1...6 {
            let limit = Self.base + UInt64(failUntil) * 1_000_000_000
            let (_, records) = await overlayRun(SpyLog(), ticks: 30, processesFailWhen: { $0.uptimeNs < limit })
            let gaps = zip(records.dropFirst(), records).map { $0.tick - $1.tick }
            #expect(gaps.allSatisfy { $0 >= 5 }, "failUntil \(failUntil): gaps \(gaps)")   // 1-s grid: ≥ 4.5 s → ≥ 5
            #expect(gaps.allSatisfy { $0 <= 6 }, "failUntil \(failUntil): gaps \(gaps)")   // overdue at 5 s + tick
            #expect(records.count >= 5)
            // Coverage: intervals after the first sum to the elapsed time between first and last record (±1 s).
            let covered = records.dropFirst().reduce(Duration.zero) { $0 + $1.record.interval }
            let elapsed = Duration.seconds((records.last?.tick ?? 0) - (records.first?.tick ?? 0))
            #expect(abs((covered - elapsed) / .seconds(1)) <= 1, "failUntil \(failUntil): \(covered) vs \(elapsed)")
        }
    }

    @Test func overlayOverdueIntervalIsTheActualGapClamped() async {
        let (_, records) = await overlayRun(SpyLog(), ticks: 13, processesFailWhen: { _ in true })
        #expect(records.map(\.tick) == [0, 6, 12])
        #expect(records.map(\.record.interval) == [.seconds(5), .seconds(6), .seconds(6)])
    }

    @Test func pausedTakesNoSamplesAndEmitsPauseEvent() async throws {
        let log = SpyLog()
        let e = engine(log)
        let frames = Collector(e.liveFrames), records = Collector(e.records)
        await e.setVisibility(UIVisibility(popoverOpen: true))
        await e.start()
        _ = await frames.wait(count: 2)
        await e.setPaused(true)
        try await Task.sleep(for: .milliseconds(30))
        let count = log.count(.processes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.count(.processes) == count)
        await e.setPaused(false)
        _ = await frames.wait(count: frames.all.count + 1)
        #expect(log.count(.processes) > count)
        await e.stop()
        #expect(await records.waitFinished())
        let paused = records.all.flatMap(\.events).filter { $0.kind == .samplingPaused }
        #expect(paused.count == 2)                                    // open + close, same id
        #expect(Set(paused.map(\.id)).count == 1)
        #expect(paused.last?.end != nil)
    }

    @Test func alertEpisodesAreDrainedOnPause() async {
        let log = SpyLog()
        let e = engine(log, memoryPressure: .critical)
        let records = Collector(e.records)
        let f = await e.sampleOnce()
        let opened = f.events.first { $0.kind == .memoryPressure }
        #expect(opened?.end == nil)
        await e.setPaused(true)
        // The pause itself drains the episode: the closed event is in `records` before stop() (not from stop's flush).
        let deadline = ContinuousClock.now + .seconds(2)
        func closed() -> HistoryEvent? {
            records.all.flatMap(\.events).first { $0.kind == .memoryPressure && $0.end != nil }
        }
        while closed() == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(!records.isFinished)
        #expect(closed()?.id == opened?.id)
        await e.stop()
        #expect(await records.waitFinished())
    }

    @Test func alertEngineResetsOnWake() async {
        let log = SpyLog()
        let e = engine(log, memoryPressure: .critical)
        let first = await e.sampleOnce().events.first { $0.kind == .memoryPressure }
        await e.systemWillSleep()
        await e.systemDidWake()
        let f = await e.sampleOnce()
        let reopened = f.events.first { $0.kind == .memoryPressure }
        #expect(reopened != nil && reopened?.id != first?.id)       // a new episode after wake
        #expect(f.alert.level == .critical && !f.alert.paused)
    }

    @Test func memoryAlertAddsDemandAndRootMemoryRuns() async {
        let log = SpyLog()
        let e = engine(log, memoryPressure: .critical)
        _ = await e.sampleOnce()                                      // tick 1: arc becomes critical
        #expect(log.count(.rootMemory) == 0)
        _ = await e.sampleOnce()                                      // tick 2: .memoryAlert in demand
        #expect(log.contexts(.processes).last?.demand.contains(.memoryAlert) == true)
        #expect(log.count(.rootMemory) == 1)
    }

    @Test func sampleContextCarriesPreviousAlertLevel() async {
        let log = SpyLog()
        let e = engine(log, memoryPressure: .critical)
        _ = await e.sampleOnce()
        _ = await e.sampleOnce()
        #expect(log.contexts(.hostCPU).map(\.alertLevel) == [.calm, .critical])
    }

    @Test func wakeResetsBaselinesAndRecordsSleep() async {
        let log = SpyLog()
        let e = engine(log)
        let records = Collector(e.records)
        _ = await e.sampleOnce()
        #expect(await e.sampleOnce().interval != nil)
        await e.systemWillSleep()
        await e.systemDidWake()
        let f = await e.sampleOnce()
        #expect(f.interval == nil)
        #expect(f.cpu.usage == nil)
        #expect(f.processes.first { $0.pid == 10 }?.cpuPercent == nil)
        await e.stop()
        #expect(await records.waitFinished())
        let sleeps = records.all.flatMap(\.events).filter { $0.kind == .systemSleep }
        #expect(sleeps.count == 2 && sleeps.last?.end != nil)
    }

    @Test func connectionsOnlyInInteractiveMode() async {
        let inspected = AppKey(kind: .app, id: "a")
        let log = SpyLog()
        let interactive = engine(log)
        await interactive.setVisibility(UIVisibility(dashboardVisible: true, page: .processes, inspectedApp: inspected))
        _ = await interactive.sampleOnce()
        let fi = await interactive.sampleOnce()
        #expect(fi.mode == .interactive)
        #expect(fi.connections.map(\.id) == [1])
        #expect(fi.connections.first?.app == inspected)

        let background = engine(SpyLog())
        await background.setVisibility(UIVisibility(popoverOpen: false, dashboardVisible: false, inspectedApp: inspected))
        _ = await background.sampleOnce()
        let fb = await background.sampleOnce()
        #expect(fb.mode == .background)
        #expect(fb.connections.isEmpty)                               // same inspected app, background: none
        #expect(fb.processes.first { $0.pid == 10 }?.connectionCount == 1)   // flows themselves were sampled
    }

    @Test func stopFinishesStreamsAndIsFinal() async {
        let log = SpyLog()
        let e = engine(log)
        let frames = Collector(e.liveFrames), records = Collector(e.records)
        await e.setPaused(true)
        await e.stop()                                                // never started: streams still finish
        let framesDone = await frames.waitFinished()
        let recordsDone = await records.waitFinished()
        #expect(framesDone && recordsDone)
        let pause = records.all.flatMap(\.events).filter { $0.kind == .samplingPaused }
        #expect(pause.count == 2 && pause.last?.end != nil)           // open pause marker closed at stop
        await e.start()                                               // no-op after stop
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.count(.processes) == 0)
    }

    @Test func sensorCostsReported() async {
        let log = SpyLog()
        let e = engine(log)
        _ = await e.sampleOnce()
        let costs = await e.sensorCosts()
        #expect(costs[.processes] != nil)
    }
}
