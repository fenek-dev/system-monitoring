import Foundation
import MonitorModel
import os
@testable import MonitorEngine

/// Index of the recorded tick the replay sensors serve next (set by the driver before each sample).
final class ReplayCursor: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var index: Int {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Serves one sensor's recorded `SensorResult`s by tick index, keeping the recorded `capturedNs`.
final class ReplaySensor<R: Sendable & Codable>: Sensor {
    typealias Reading = R
    let id: SensorID
    let cadence: SensorCadence = .everyTick
    private let results: [SensorResult<R>]
    private let cursor: ReplayCursor

    init(_ id: SensorID, _ results: [SensorResult<R>], cursor: ReplayCursor) {
        self.id = id
        self.results = results
        self.cursor = cursor
    }

    func prepare() throws(SensorError) {}
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        let i = min(cursor.index, results.count - 1)
        switch results[i] {
        case .fresh(let r, let ns), .cached(let r, let ns): return (r, ns)
        case .failed(let e, _, _): throw e
        case .notRequested: throw .transient("not recorded")
        }
    }
    func invalidate() {}
}

/// Replays `RawTick`s through a real `SamplingEngine` (sensor slots, assembler, alerts), driving sleep/wake the way
/// the app does: when the recording's wall clock moved much further than its uptime (the machine slept), the driver
/// calls `systemWillSleep()`/`systemDidWake()` before the next sample.
enum FixtureReplay {
    /// A wall-clock gap this much larger than the uptime gap means the machine slept (uptime stops during sleep).
    static let sleepSlack: TimeInterval = 10

    struct Step {
        var tick: RawTick
        var frame: SystemFrame
        var afterWake: Bool
    }

    /// Grouping without disk access (fixtures come from other machines): bundle keys fall back to bundle paths.
    /// Current user = the recording's own user: the most common uid ≥ 500 among non-restricted processes (fixtures carry no
    /// metadata; recordings come from machines whose login uid isn't necessarily 501).
    static func resolver(_ ticks: [RawTick] = []) -> any AppResolving {
        BundleAppResolver(currentUID: recordingUID(ticks), readInfoPlist: { _ in nil })
    }

    static func recordingUID(_ ticks: [RawTick]) -> uid_t {
        var counts: [UInt32: Int] = [:]
        for t in ticks {
            for p in t.processes.value?.processes ?? [] where !p.restricted && p.uid >= 500 { counts[p.uid, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 501
    }

    static func slept(_ a: RawTick, _ b: RawTick) -> Bool {
        let wall = b.wallTime.timeIntervalSince(a.wallTime)
        let up = Double(b.uptimeNs >= a.uptimeNs ? b.uptimeNs - a.uptimeNs : 0) / 1e9
        return wall - up > sleepSlack
    }

    static func replayThroughEngine(_ ticks: [RawTick]) async -> [Step] {
        let cursor = ReplayCursor()
        let factory = SensorFactory { _ in suite(ticks, cursor) }
        let engine = SamplingEngine(factory: factory, resolver: { resolver(ticks) },
                                    interactiveInterval: .seconds(1), backgroundInterval: .seconds(5))
        var steps: [Step] = []
        for (i, t) in ticks.enumerated() {
            cursor.index = i
            let woke = i > 0 && slept(ticks[i - 1], t)
            if woke {
                await engine.systemWillSleep()
                await engine.systemDidWake()
            }
            let (_, frame) = await engine.sampleOnceRaw()
            steps.append(Step(tick: t, frame: frame, afterWake: woke))
        }
        await engine.stop()
        return steps
    }

    /// A bare `FrameAssembler` with no wake handling: shows what the engine's reset protects against.
    static func replayWithoutWakeReset(_ ticks: [RawTick]) -> [SystemFrame] {
        var fa = FrameAssembler(resolver: resolver(ticks))
        return ticks.map { fa.assemble($0, inspectedApp: nil) }
    }

    /// `Fixtures/recorded/*.json` (W7 `telltale-probe --record`) in the `RawTick.fixtureDecoder` format.
    static func recordedFixtures() throws -> [(name: String, ticks: [RawTick])] {
        guard let base = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/recorded") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.map { url in
            (url.lastPathComponent, try RawTick.fixtureDecoder.decode([RawTick].self, from: Data(contentsOf: url)))
        }
    }

    private static func suite(_ ticks: [RawTick], _ c: ReplayCursor) -> SensorSuite {
        SensorSuite(
            processes: ReplaySensor(.processes, ticks.map(\.processes), cursor: c),
            coalitions: ReplaySensor(.coalitions, ticks.map(\.coalitions), cursor: c),
            rootMemory: ReplaySensor(.rootMemory, ticks.map(\.rootMemory), cursor: c),
            hostCPU: ReplaySensor(.hostCPU, ticks.map(\.hostCPU), cursor: c),
            memory: ReplaySensor(.memory, ticks.map(\.memory), cursor: c),
            soc: ReplaySensor(.soc, ticks.map(\.soc), cursor: c),
            gpuClients: ReplaySensor(.gpuClients, ticks.map(\.gpuClients), cursor: c),
            temperatures: ReplaySensor(.temperatures, ticks.map(\.temperatures), cursor: c),
            smc: ReplaySensor(.smc, ticks.map(\.smc), cursor: c),
            thermalState: ReplaySensor(.thermalState, ticks.map(\.thermalState), cursor: c),
            networkFlows: ReplaySensor(.networkFlows, ticks.map(\.networkFlows), cursor: c),
            interfaces: ReplaySensor(.interfaces, ticks.map(\.interfaces), cursor: c),
            wifi: ReplaySensor(.wifi, ticks.map(\.wifi), cursor: c),
            latency: ReplaySensor(.latency, ticks.map(\.latency), cursor: c),
            diskIO: ReplaySensor(.diskIO, ticks.map(\.diskIO), cursor: c),
            volumes: ReplaySensor(.volumes, ticks.map(\.volumes), cursor: c),
            smart: ReplaySensor(.smart, ticks.map(\.smart), cursor: c),
            battery: ReplaySensor(.battery, ticks.map(\.battery), cursor: c),
            sleepAssertions: ReplaySensor(.sleepAssertions, ticks.map(\.sleepAssertions), cursor: c),
            device: ReplaySensor(.device, ticks.map(\.device), cursor: c))
    }
}

/// Synthetic stand-in for W7's recordings (until they exist): 8 cores, an app with two helpers, eight `yes`
/// processes, a restricted two-member coalition (WindowServer + MTLCompilerService), kernel_task alone, AGX, and a
/// sleep after tick `wakeAt − 1`: wall clock +1 h, uptime +1 s, while every cumulative counter jumps by an hour's
/// worth of work (dark-wake activity) — so replay without the wake reset spikes.
enum SyntheticRecording {
    static let cores = 8
    static let wakeAt = 12
    static let sleptSeconds: Double = 3_600

    static func ticks(count: Int = 20) -> [RawTick] {
        let base = Date(timeIntervalSince1970: 1_790_000_000.25)
        return (0..<count).map { i in
            let n = UInt64(i + 1)
            let slept = i >= wakeAt
            let wall = base.addingTimeInterval(Double(i) + (slept ? sleptSeconds : 0))
            let t = n * 1_000_000_000                                          // uptime: +1 s per tick, also across sleep
            let work = Double(t) + (slept ? sleptSeconds * 1e9 : 0)            // counters: include the hour asleep
            let secs = work / 1e9
            let cpu: (Double) -> UInt64 = { UInt64($0 / 100 * work) }
            let nj: (Double) -> UInt64 = { UInt64($0 * secs * 1e9) }          // watts → cumulative nJ
            var procs = [
                RawProcess(id: ProcessID(pid: 100, startTimeUs: 1), uid: 501, comm: "Editor", name: "Editor",
                           path: "/Applications/Editor.app/Contents/MacOS/Editor", cpuTimeNs: cpu(20), footprint: 400 << 20,
                           diskReadBytes: 0, diskWriteBytes: UInt64(secs * 1_000), energyNJ: nj(0.3)),
                RawProcess(id: ProcessID(pid: 101, startTimeUs: 1), uid: 501, comm: "Editor Helper", name: "Editor Helper",
                           path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper",
                           responsiblePID: 100, cpuTimeNs: cpu(5), footprint: 100 << 20, diskReadBytes: 0,
                           diskWriteBytes: 0, energyNJ: nj(0.05)),
                RawProcess(id: ProcessID(pid: 102, startTimeUs: 1), uid: 501, comm: "Editor Helper", name: "Editor Helper",
                           path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper",
                           responsiblePID: 100, cpuTimeNs: cpu(5), footprint: 100 << 20, diskReadBytes: 0,
                           diskWriteBytes: 0, energyNJ: nj(0.05)),
                RawProcess(id: ProcessID(pid: 418, startTimeUs: 1), uid: 88, comm: "WindowServer",
                           path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", restricted: true),
                RawProcess(id: ProcessID(pid: 419, startTimeUs: 1), uid: 88, comm: "MTLCompilerServi", restricted: true),
                RawProcess(id: ProcessID(pid: 0, startTimeUs: 1), uid: 0, comm: "kernel_task", restricted: true),
            ]
            for k in 0..<8 {
                procs.append(RawProcess(id: ProcessID(pid: Int32(200 + k), startTimeUs: 1), uid: 501, comm: "yes",
                                        name: "yes", path: "/usr/bin/yes", cpuTimeNs: cpu(85), footprint: 1 << 20,
                                        diskReadBytes: 0, diskWriteBytes: 0, energyNJ: nj(3)))
            }
            // Host ticks (1 ms units): 780 % of 800 → 97.5 % busy per core
            let ms = UInt64(secs * 1_000)
            let busy = ms * 975 / 1_000
            let host = HostCPUReading(cores: (0..<cores).map { _ in CoreTicks(user: busy * 3 / 4, system: busy / 4, idle: ms - busy) },
                                      coreKinds: Array(repeating: .performance, count: cores), loadAverage: [8, 7, 5])
            let coalitions = CoalitionsReading(coalitions: [
                CoalitionUsage(id: 7, leaderPID: 418, memberPIDs: [418, 419], cpuTimeNs: cpu(30), energyNJ: nj(0.2)),
                CoalitionUsage(id: 1, leaderPID: 0, memberPIDs: [0], cpuTimeNs: cpu(10), energyNJ: nj(0.1)),
                CoalitionUsage(id: 50, leaderPID: 100, memberPIDs: [100, 101, 102] + (200..<208).map { Int32($0) },
                               cpuTimeNs: cpu(30 + 680), energyNJ: nj(24)),
            ])
            let gpu = GPUClientsReading(clients: [
                GPUClientCounter(clientID: 1, pid: 418, creatorName: "WindowServer", gpuTimeNs: UInt64(0.15 * work)),
                GPUClientCounter(clientID: 2, pid: 101, creatorName: "Editor Helper", gpuTimeNs: UInt64(0.05 * work)),
            ])
            let soc = SoCPowerReading(interval: .seconds(1), cpuWatts: 30, gpuWatts: 2, gpuActiveFraction: 0.2)
            let mem = MemoryReading(pageSize: 16_384, total: 32 << 30, free: 4 << 30, wired: 3 << 30, anonymous: 12 << 30,
                                    compressorBytes: 1 << 30, pressureLevel: .normal, pressureFraction: 0.3)
            return RawTick(wallTime: wall, uptimeNs: t, mode: .interactive,
                           processes: .fresh(ProcessTableReading(processes: procs), capturedNs: t),
                           coalitions: .fresh(coalitions, capturedNs: t),
                           hostCPU: .fresh(host, capturedNs: t),
                           memory: .fresh(mem, capturedNs: t),
                           soc: .fresh(soc, capturedNs: t),
                           gpuClients: .fresh(gpu, capturedNs: t),
                           thermalState: .fresh(.nominal, capturedNs: t),
                           device: .fresh(DeviceInfo(modelName: "Test Mac", performanceCores: cores), capturedNs: t))
        }
    }
}
