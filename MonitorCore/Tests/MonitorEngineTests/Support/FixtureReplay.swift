import Foundation
import MonitorModel
@testable import MonitorEngine

/// Replays `RawTick`s through a `FrameAssembler` like the sampling engine does, including the wake reset.
struct FixtureReplay {
    /// A wall-clock gap this much larger than the uptime gap means the machine slept (uptime stops during sleep).
    static let sleepSlack: TimeInterval = 10

    struct Step {
        var tick: RawTick
        var frame: SystemFrame
        var afterWake: Bool
    }

    static func replay(_ ticks: [RawTick], resolver: any AppResolving = BundleAppResolver()) -> [Step] {
        var fa = FrameAssembler(resolver: resolver)
        var out: [Step] = []
        var previous: RawTick?
        for t in ticks {
            var woke = false
            if let p = previous {
                let wall = t.wallTime.timeIntervalSince(p.wallTime)
                let up = Double(t.uptimeNs >= p.uptimeNs ? t.uptimeNs - p.uptimeNs : 0) / 1e9
                if wall - up > sleepSlack {
                    fa.reset()
                    woke = true
                }
            }
            out.append(Step(tick: t, frame: fa.assemble(t, inspectedApp: nil), afterWake: woke))
            previous = t
        }
        return out
    }

    /// `Fixtures/recorded/*.json` (W7 `telltale-probe --record`): a JSON array of `RawTick`.
    static func recordedFixtures() throws -> [(name: String, ticks: [RawTick])] {
        guard let base = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/recorded") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.map { url in
            (url.lastPathComponent, try decoder.decode([RawTick].self, from: Data(contentsOf: url)))
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

/// Synthetic stand-in for W7's recordings (until they exist): 8 cores, an app with two helpers, eight `yes`
/// processes, a restricted two-member coalition (WindowServer + MTLCompilerService), kernel_task alone, AGX, and a
/// sleep/wake after tick `wakeAt` (wall clock +1 h, uptime +1 s).
enum SyntheticRecording {
    static let cores = 8
    static let wakeAt = 12

    static func ticks(count: Int = 20) -> [RawTick] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { i in
            let n = UInt64(i + 1)
            let slept = i >= wakeAt
            let wall = base.addingTimeInterval(Double(i) + (slept ? 3_600 : 0))
            let t = n * 1_000_000_000
            // per second: editor 20 %, helpers 5 % each, 8× yes 85 %, WindowServer+MTL 30 %, kernel_task 10 %
            let cpu: (Double) -> UInt64 = { UInt64($0 / 100 * Double(t)) }
            var procs = [
                RawProcess(id: ProcessID(pid: 100, startTimeUs: 1), uid: 501, comm: "Editor", name: "Editor",
                           path: "/Applications/Editor.app/Contents/MacOS/Editor", cpuTimeNs: cpu(20), footprint: 400 << 20,
                           diskReadBytes: 0, diskWriteBytes: n * 1_000, energyNJ: n * 300_000_000),
                RawProcess(id: ProcessID(pid: 101, startTimeUs: 1), uid: 501, comm: "Editor Helper", name: "Editor Helper",
                           path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper",
                           responsiblePID: 100, cpuTimeNs: cpu(5), footprint: 100 << 20, diskReadBytes: 0,
                           diskWriteBytes: 0, energyNJ: n * 50_000_000),
                RawProcess(id: ProcessID(pid: 102, startTimeUs: 1), uid: 501, comm: "Editor Helper", name: "Editor Helper",
                           path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper",
                           responsiblePID: 100, cpuTimeNs: cpu(5), footprint: 100 << 20, diskReadBytes: 0,
                           diskWriteBytes: 0, energyNJ: n * 50_000_000),
                RawProcess(id: ProcessID(pid: 418, startTimeUs: 1), uid: 88, comm: "WindowServer",
                           path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", restricted: true),
                RawProcess(id: ProcessID(pid: 419, startTimeUs: 1), uid: 88, comm: "MTLCompilerServi", restricted: true),
                RawProcess(id: ProcessID(pid: 0, startTimeUs: 1), uid: 0, comm: "kernel_task", restricted: true),
            ]
            for k in 0..<8 {
                procs.append(RawProcess(id: ProcessID(pid: Int32(200 + k), startTimeUs: 1), uid: 501, comm: "yes",
                                        name: "yes", path: "/usr/bin/yes", cpuTimeNs: cpu(85), footprint: 1 << 20,
                                        diskReadBytes: 0, diskWriteBytes: 0, energyNJ: n * 3_000_000_000))
            }
            // Host ticks: total 780 % of 800 → 97.5 % busy per core (in mach-tick-like units of 1 ms)
            let ms = n * 1_000
            let busy = ms * 975 / 1_000
            let host = HostCPUReading(cores: (0..<cores).map { _ in CoreTicks(user: busy * 3 / 4, system: busy / 4, idle: ms - busy) },
                                      coreKinds: Array(repeating: .performance, count: cores), loadAverage: [8, 7, 5])
            let coalitions = CoalitionsReading(coalitions: [
                CoalitionUsage(id: 7, leaderPID: 418, memberPIDs: [418, 419], cpuTimeNs: cpu(30), energyNJ: n * 200_000_000),
                CoalitionUsage(id: 1, leaderPID: 0, memberPIDs: [0], cpuTimeNs: cpu(10), energyNJ: n * 100_000_000),
                CoalitionUsage(id: 50, leaderPID: 100, memberPIDs: [100, 101, 102] + (200..<208).map { Int32($0) },
                               cpuTimeNs: cpu(30 + 680), energyNJ: n * 24_000_000_000),
            ])
            let gpu = GPUClientsReading(clients: [
                GPUClientCounter(clientID: 1, pid: 418, creatorName: "WindowServer", gpuTimeNs: n * 150_000_000),
                GPUClientCounter(clientID: 2, pid: 101, creatorName: "Editor Helper", gpuTimeNs: n * 50_000_000),
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
