import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Hardware smoke: opt-in, run one suite at a time at checkpoints; never in parallel with other suites or builds
/// (load-sensitive). `TELLTALE_HW_TESTS=1 swift test --no-parallel --filter RootMemorySmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized, .offCooperativePool)
struct RootMemorySmokeTests {
    @Test func rootPidsHaveRSSMatchingPs() throws {
        let sensor = RootMemorySensor()
        try sensor.prepare()
        let r = try sensor.sample(SampleContext()).reading.rssByPID
        let ref = try W6aFixture.run(["/bin/ps", "-Ao", "pid=,user=,rss="])
        let refLines = ref.split(separator: "\n").count
        var compared = 0, within = 0
        for line in ref.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "root", let pid = Int32(f[0]), let kb = UInt64(f[2]), kb > 10_000,
                  let ours = r[pid] else { continue }
            compared += 1
            let ratio = Double(ours) / Double(kb * 1024)
            if ratio > 0.7 && ratio < 1.3 { within += 1 }
        }
        print("W6a rootMemory: pids=\(r.count) rootCompared=\(compared) within±30%=\(within) launchd=\((r[1] ?? 0) >> 20)MB")
        #expect(abs(r.count - refLines) <= max(refLines / 20, 10))   // same pid set ± churn
        #expect(r[1] != nil)
        #expect(compared > 0)
        #expect(within >= compared * 9 / 10)
    }

    @Test func bench() throws {
        var ns: [UInt64] = []
        for _ in 0..<10 {
            let t = w6aUptimeNs()
            _ = RootMemoryParser.parse(try RootMemoryFFI.runPS(RunCancellation()))
            ns.append(w6aUptimeNs() - t)
        }
        let sensor = RootMemorySensor()
        _ = try sensor.sample(SampleContext())
        var call: [UInt64] = []
        for _ in 0..<10 {
            let t = w6aUptimeNs()
            _ = try sensor.sample(SampleContext())
            call.append(w6aUptimeNs() - t)
        }
        print("W6a bench rootMemory ps-run(off-queue) \(W6aFixture.percentiles(ns)); sample() \(W6aFixture.percentiles(call))")
    }
}
