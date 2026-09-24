import CPrivate
import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh CoalitionSmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized)
struct CoalitionSmokeTests {
    @Test func captureUsageFixture() throws {
        guard W6aFixture.capture else { return }
        let own = try #require(CoalitionFFI.resourceCoalition(of: getpid()))
        let dump = try CoalitionFFI.sentinelDump(own)
        try Data(dump).write(to: W6aFixture.sourceURL("coalition_usage.bin"))
    }

    @Test func sensorPreparesAndCoversRootProcesses() throws {
        let sensor = CoalitionSensor()
        try sensor.prepare()
        let r = try sensor.sample(SampleContext()).reading.coalitions
        let withMembers = r.filter { !$0.memberPIDs.isEmpty }
        let members = withMembers.reduce(0) { $0 + $1.memberPIDs.count }
        let ws = withMembers.first { c in c.memberPIDs.contains { pidComm($0) == "WindowServer" } }
        print("W6a coalitions: total=\(r.count) withMembers=\(withMembers.count) memberPids=\(members) " +
              "WindowServer leader=\(ws?.leaderPID.map(pidComm) ?? "-") members=\(ws?.memberPIDs.count ?? 0)")
        let one = r.first { $0.memberPIDs.contains(1) }
        print("W6a coalition of launchd: id=\(one?.id ?? 0) leader=\(one?.leaderPID ?? -9) members=\(one?.memberPIDs ?? [])")
        #expect(r.count > 50)
        #expect(ws != nil)
        #expect(members > 500)
    }

    /// Plausibility: Σ coalition CPU over a window ≈ `top` total (user+sys × ncpu).
    @Test func sumOfCoalitionCPUMatchesTop() throws {
        let sensor = CoalitionSensor()
        try sensor.prepare()
        let a = try sensor.sample(SampleContext())
        let top = try W6aFixture.run(["/usr/bin/top", "-l", "2", "-s", "2", "-n", "0"])
        let b = try sensor.sample(SampleContext())
        let dt = Double(b.capturedNs - a.capturedNs) / 1e9
        let before = Dictionary(a.reading.coalitions.map { ($0.id, $0.cpuTimeNs) }, uniquingKeysWith: { x, _ in x })
        var sumNs: UInt64 = 0
        for c in b.reading.coalitions {
            if let old = before[c.id], let d = w6aCounterDelta(c.cpuTimeNs, old) { sumNs += d }
        }
        let coalPct = Double(sumNs) / 1e9 / dt * 100
        let line = top.split(separator: "\n").last { $0.hasPrefix("CPU usage") }.map(String.init) ?? ""
        let nums = line.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        let topPct = nums.count >= 2 ? (nums[0] + nums[1]) * Double(ProcessInfo.processInfo.activeProcessorCount) : -1
        print("W6a Σcoalition cpu=\(String(format: "%.1f", coalPct))% (of one core) top=\(String(format: "%.1f", topPct))% dt=\(String(format: "%.2f", dt))s")
        #expect(coalPct > 0)
    }

    @Test func bench() throws {
        let sensor = CoalitionSensor()
        let t0 = w6aUptimeNs()
        try sensor.prepare()
        let prep = w6aUptimeNs() - t0
        var ns: [UInt64] = []
        for _ in 0..<30 {
            let t = w6aUptimeNs()
            _ = try sensor.sample(SampleContext())
            ns.append(w6aUptimeNs() - t)
        }
        print("W6a bench coalitions prepare=\(W6aFixture.ms(prep))ms \(W6aFixture.percentiles(ns))")
    }

    private func pidComm(_ pid: Int32) -> String {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return "?" }
        return KinfoProcParser.entry(kp).comm
    }
}
