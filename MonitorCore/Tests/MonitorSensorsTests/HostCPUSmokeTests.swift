import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Hardware smoke: opt-in, run one suite at a time at checkpoints; never in parallel with other suites or builds
/// (load-sensitive). `TELLTALE_HW_TESTS=1 swift test --no-parallel --filter HostCPUSmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized)
struct HostCPUSmokeTests {
    @Test func captureDeviceTree() throws {
        guard W6aFixture.capture else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(HostCPUFFI.deviceTreeCores()).write(to: W6aFixture.sourceURL("cpus_devicetree.json"))
    }

    @Test func busyFractionMatchesTop() throws {
        let yes = try W6aFixture.spawnYes()   // controlled load: ≥ 1 core busy
        defer { yes.terminate(); yes.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.3)
        let sensor = HostCPUSensor()
        try sensor.prepare()
        // Our window [a, b] brackets top's 2 s window.
        let a = try sensor.sample(SampleContext()).reading
        let top = try W6aFixture.run(["/usr/bin/top", "-l", "2", "-s", "2", "-n", "0"])
        let b = try sensor.sample(SampleContext()).reading
        var busy: UInt64 = 0, total: UInt64 = 0
        for (x, y) in zip(a.cores, b.cores) {
            guard let u = w6aCounterDelta(y.user, x.user), let s = w6aCounterDelta(y.system, x.system),
                  let i = w6aCounterDelta(y.idle, x.idle), let n = w6aCounterDelta(y.nice, x.nice) else { continue }
            busy += u + s + n
            total += u + s + n + i
        }
        let ours = total > 0 ? Double(busy) / Double(total) * 100 : -1
        let line = top.split(separator: "\n").last { $0.hasPrefix("CPU usage") }.map(String.init) ?? ""
        let nums = line.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        let topBusy = nums.count >= 2 ? nums[0] + nums[1] : -1
        let p = b.coreKinds.filter { $0 == .performance }.count, e = b.coreKinds.filter { $0 == .efficiency }.count
        print("W6a hostCPU: cores=\(b.cores.count) P=\(p) E=\(e) kinds=\(b.coreKinds.map { $0 == .performance ? "P" : "E" }.joined()) " +
              "busy=\(String(format: "%.1f", ours))% top=\(String(format: "%.1f", topBusy))% load=\(b.loadAverage.map { String(format: "%.2f", $0) })")
        #expect(b.cores.count == ProcessInfo.processInfo.activeProcessorCount)
        #expect(p == HostCPUFFI.sysctlInt("hw.perflevel0.logicalcpu"))
        #expect(ours > 0 && ours <= 100)
        #expect(topBusy >= 0)
        #expect(abs(ours - topBusy) <= max(0.3 * topBusy, 5))   // ±30 %, 5-point floor for idle noise
        #expect(b.loadAverage.count == 3)
    }

    @Test func bench() throws {
        let sensor = HostCPUSensor()
        try sensor.prepare()
        var ns: [UInt64] = []
        for _ in 0..<30 {
            let t = w6aUptimeNs()
            _ = try sensor.sample(SampleContext())
            ns.append(w6aUptimeNs() - t)
        }
        print("W6a bench hostCPU \(W6aFixture.percentiles(ns))")
    }
}
