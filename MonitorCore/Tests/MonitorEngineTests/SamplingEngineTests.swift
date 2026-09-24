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
    let make: (SampleContext) -> R

    init(_ id: SensorID, cadence: SensorCadence = .everyTick, log: SpyLog, make: @escaping (SampleContext) -> R) {
        self.id = id
        self.cadence = cadence
        self.log = log
        self.make = make
    }

    func prepare() throws(SensorError) {}
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        log.record(id, ctx)
        return (make(ctx), ctx.uptimeNs)
    }
    func invalidate() {}
}

private func factory(_ log: SpyLog, memoryPressure: MemoryPressureLevel = .normal) -> SensorFactory {
    SensorFactory { _ in
        SensorSuite(
            processes: SpySensor(.processes, log: log) { ctx in
                ProcessTableReading(processes: [own(10, cpuNs: ctx.uptimeNs / 2, energyNJ: ctx.uptimeNs)])
            },
            rootMemory: SpySensor(.rootMemory, cadence: .every(.zero, background: .zero, requires: [.processTable, .memoryAlert]),
                                  log: log) { _ in RootMemoryReading() },
            hostCPU: SpySensor(.hostCPU, log: log) { ctx in
                let t = ctx.uptimeNs / 1_000_000
                return HostCPUReading(cores: [CoreTicks(user: t / 2, idle: t / 2)], coreKinds: [.performance])
            },
            memory: SpySensor(.memory, log: log) { _ in MemoryReading(total: 1 << 34, pressureLevel: memoryPressure) })
    }
}

private func engine(_ log: SpyLog, memoryPressure: MemoryPressureLevel = .normal,
                    interactive: Duration = .milliseconds(20), background: Duration = .milliseconds(60)) -> SamplingEngine {
    SamplingEngine(factory: factory(log, memoryPressure: memoryPressure), resolver: { FixtureAppResolver([10: appID("a")]) },
                   interactiveInterval: interactive, backgroundInterval: background)
}

/// Collects up to `count` frames or gives up after `timeout`.
private func frames(_ e: SamplingEngine, count: Int, timeout: Duration = .seconds(2)) async -> [SystemFrame] {
    await withTaskGroup(of: [SystemFrame].self) { group in
        group.addTask {
            var out: [SystemFrame] = []
            for await f in e.liveFrames {
                out.append(f)
                if out.count == count { break }
            }
            return out
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return []
        }
        var result: [SystemFrame] = []
        for await r in group where !r.isEmpty || result.isEmpty {
            result = r
            group.cancelAll()
            break
        }
        return result
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
        await e.setVisibility(UIVisibility(popoverOpen: true))
        await e.start()
        let got = await frames(e, count: 4)
        #expect(got.count == 4)
        #expect(got.allSatisfy { $0.mode == .interactive })
        let gaps = zip(got.dropFirst(), got).map { Double($0.uptimeNs - $1.uptimeNs) / 1e6 }
        #expect(gaps.allSatisfy { $0 >= 15 && $0 < 500 })           // ~20 ms cadence
        var batches = 0
        for await b in e.records {
            if b.record != nil { batches += 1 }
            if batches >= 3 { break }
        }
        #expect(batches >= 3)
        await e.stop()
    }

    @Test func becomingInteractiveWakesTheSleeper() async {
        let log = SpyLog()
        let e = engine(log, background: .seconds(30))
        await e.start()
        _ = await frames(e, count: 1)                                 // immediate first background sample
        let before = log.count(.processes)
        let start = ContinuousClock.now
        await e.setVisibility(UIVisibility(popoverOpen: true))
        let next = await frames(e, count: 1, timeout: .seconds(2))
        let latency = ContinuousClock.now - start
        #expect(next.first?.mode == .interactive)
        #expect(log.count(.processes) > before)
        #expect(latency < .milliseconds(250))                         // 30 s background sleep was cut short
        print("PERF wake-up latency \(latency)")
        await e.stop()
    }

    @Test func pausedTakesNoSamplesAndEmitsPauseEvent() async throws {
        let log = SpyLog()
        let e = engine(log)
        await e.setVisibility(UIVisibility(popoverOpen: true))
        await e.start()
        _ = await frames(e, count: 2)
        await e.setPaused(true)
        try await Task.sleep(for: .milliseconds(30))
        let count = log.count(.processes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.count(.processes) == count)
        await e.setPaused(false)
        _ = await frames(e, count: 1)
        #expect(log.count(.processes) > count)
        await e.stop()
        var kinds: [HistoryEvent.Kind] = []
        var paused: [HistoryEvent] = []
        for await b in e.records {
            kinds += b.events.map(\.kind)
            paused += b.events.filter { $0.kind == .samplingPaused }
        }
        #expect(paused.count == 2)                                    // open + close, same id
        #expect(Set(paused.map(\.id)).count == 1)
        #expect(paused.last?.end != nil)
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
        _ = await e.sampleOnce()
        #expect(await e.sampleOnce().interval != nil)
        await e.systemWillSleep()
        await e.systemDidWake()
        let f = await e.sampleOnce()
        #expect(f.interval == nil)
        #expect(f.cpu.usage == nil)
        #expect(f.processes.first { $0.pid == 10 }?.cpuPercent == nil)
        await e.start()
        await e.stop()
        var sleeps: [HistoryEvent] = []
        for await b in e.records { sleeps += b.events.filter { $0.kind == .systemSleep } }
        #expect(sleeps.count == 2 && sleeps.last?.end != nil)
    }

    @Test func connectionsOnlyInInteractiveMode() async {
        let log = SpyLog()
        let e = engine(log)
        await e.setVisibility(UIVisibility(popoverOpen: false, dashboardVisible: false, inspectedApp: AppKey(kind: .app, id: "a")))
        let ctx = log.contexts(.processes)
        #expect(ctx.isEmpty)
        let f = await e.sampleOnce()                                  // background: no inspected app passed on
        #expect(f.mode == .background)
        #expect(f.connections.isEmpty)
    }

    @Test func sensorCostsReported() async {
        let log = SpyLog()
        let e = engine(log)
        _ = await e.sampleOnce()
        let costs = await e.sensorCosts()
        #expect(costs[.processes] != nil)
    }
}
