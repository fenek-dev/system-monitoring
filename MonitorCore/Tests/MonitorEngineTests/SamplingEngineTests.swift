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

    init(_ id: SensorID, cadence: SensorCadence = .everyTick, log: SpyLog, delay: useconds_t = 0,
         make: @escaping (SampleContext) -> R) {
        self.id = id
        self.cadence = cadence
        self.log = log
        self.delay = delay
        self.make = make
    }

    func prepare() throws(SensorError) {}
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        log.record(id, ctx)
        if delay > 0 { usleep(delay) }
        return (make(ctx), ctx.uptimeNs)
    }
    func invalidate() {}
}

private func factory(_ log: SpyLog, memoryPressure: MemoryPressureLevel = .normal, tickDelay: useconds_t = 0) -> SensorFactory {
    SensorFactory { _ in
        SensorSuite(
            processes: SpySensor(.processes, log: log, delay: tickDelay) { ctx in
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
                    interactive: Duration = .milliseconds(20), background: Duration = .milliseconds(60)) -> SamplingEngine {
    SamplingEngine(factory: factory(log, memoryPressure: memoryPressure, tickDelay: tickDelay),
                   resolver: { FixtureAppResolver([10: appID("a")]) },
                   interactiveInterval: interactive, backgroundInterval: background)
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
        await e.stop()
        #expect(await records.waitFinished())
        let closed = records.all.flatMap(\.events).first { $0.kind == .memoryPressure }
        #expect(closed?.id == opened?.id)
        #expect(closed?.end != nil)
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
