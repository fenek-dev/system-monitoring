import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Live FFI on this Mac. Hardware smoke: opt-in, run one suite at a time at checkpoints; never in parallel with
/// other suites or builds (load-sensitive). `TELLTALE_HW_TESTS=1 swift test --no-parallel --filter ProcessTableSmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized)
struct ProcessTableSmokeTests {
    @Test func captureKinfoFixture() throws {
        guard W6aFixture.capture else { return }
        let pids: [Int32] = [1, getppid(), getpid()]   // ps -p 0 prints nothing
        var bytes = Data()
        var expected: [KinfoEntry] = []
        for pid in pids {
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            #expect(sysctl(&mib, 4, &kp, &size, nil, 0) == 0)
            bytes.append(Data(bytes: &kp, count: MemoryLayout<kinfo_proc>.stride))
            let ps = try W6aFixture.run(["/bin/ps", "-o", "pid=,ppid=,uid=,ucomm=", "-p", "\(pid)"])
                .split(separator: " ", omittingEmptySubsequences: true)
            try #require(ps.count >= 4)
            let tv = kp.kp_proc.p_un.__p_starttime
            expected.append(KinfoEntry(pid: Int32(ps[0])!, ppid: Int32(ps[1])!, uid: UInt32(ps[2])!,
                                       comm: ps[3...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                                       startTimeUs: UInt64(tv.tv_sec) * 1_000_000 + UInt64(tv.tv_usec)))
        }
        try bytes.write(to: W6aFixture.sourceURL("kinfo_proc.bin"))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(expected).write(to: W6aFixture.sourceURL("kinfo_proc.expected.json"))
    }

    @Test func tableMatchesPsAndReportsRootPaths() throws {
        let sensor = ProcessTableSensor()
        try sensor.prepare()
        let rows = try sensor.sample(SampleContext()).reading.processes
        let psOut = try W6aFixture.run(["/bin/ps", "-Axo", "pid=,uid="])
        var psUID: [Int32: UInt32] = [:]
        for line in psOut.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count == 2, let p = Int32(f[0]), let u = UInt32(f[1]) { psUID[p] = u }
        }
        let ours = Dictionary(rows.map { ($0.id.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let common = Set(ours.keys).intersection(psUID.keys)
        let uidMismatch = common.filter { ours[$0]!.uid != psUID[$0]! }.count
        let me = getuid()
        let foreign = rows.filter { $0.uid != me }
        let restricted = rows.filter(\.restricted)
        let rootPaths = rows.filter { $0.uid == 0 && $0.path != nil }.count
        let rootCount = rows.filter { $0.uid == 0 }.count
        let rootNames = rows.filter { $0.uid == 0 && $0.name != nil }.count
        let withResp = rows.filter { $0.responsiblePID != nil }.count
        let d = sensor.diagnostics
        print("W6a processes: rows=\(rows.count) ps=\(psUID.count) common=\(common.count) uidMismatch=\(uidMismatch) " +
              "foreign=\(foreign.count) restricted=\(restricted.count) rootPaths=\(rootPaths)/\(rootCount) " +
              "rootNames=\(rootNames)/\(rootCount) responsible=\(withResp) v6=\(d?.v6 ?? false) resp=\(d?.responsibility ?? false)")
        for p in [0, 1] as [Int32] { print("W6a pid \(p): comm=\(ours[p]?.comm ?? "-") path=\(ours[p]?.path ?? "nil")") }
        #expect(Double(common.count) >= 0.95 * Double(psUID.count))
        #expect(uidMismatch == 0)
        #expect(ours[getpid()]?.restricted == false)
        #expect(ours[getpid()]?.energyNJ != nil)
        #expect(ours[1]?.restricted == true)
        #expect(ours[1]?.comm == "launchd")
    }

    /// Controlled load: a `yes` child pinned at ~100 %. Our Δcpu over the window vs `ps -o time=` Δ over the same
    /// window (±30 %, floor 10 points); `top -pid` printed for context (its window is only the middle 2 s).
    @Test func cpuDeltaOfYesChildMatchesPs() throws {
        let yes = try W6aFixture.spawnYes()
        defer { yes.terminate(); yes.waitUntilExit() }
        let pid = yes.processIdentifier
        Thread.sleep(forTimeInterval: 0.3)
        let sensor = ProcessTableSensor()
        try sensor.prepare()
        let psA = try #require(try W6aFixture.psCPUSeconds(pid))
        let a = try sensor.sample(SampleContext())
        let top = try W6aFixture.run(["/usr/bin/top", "-l", "2", "-s", "2", "-pid", "\(pid)", "-stats", "pid,cpu"])
        let b = try sensor.sample(SampleContext())
        let psB = try #require(try W6aFixture.psCPUSeconds(pid))
        let dt = Double(b.capturedNs - a.capturedNs) / 1e9
        let old = a.reading.processes.first { $0.id.pid == pid }?.cpuTimeNs
        let new = b.reading.processes.first { $0.id.pid == pid }?.cpuTimeNs
        let delta = try #require(old.flatMap { o in new.flatMap { w6aCounterDelta($0, o) } })
        let ours = Double(delta) / 1e9
        let ref = psB - psA
        print("W6a yes cpu: ours=\(String(format: "%.2f", ours))s ps=\(String(format: "%.2f", ref))s " +
              "(\(String(format: "%.1f", ours / dt * 100))% over \(String(format: "%.2f", dt))s; top=\(W6aFixture.topValue(top, pid: pid) ?? -1)%)")
        #expect(abs(ours - ref) / dt * 100 <= max(0.3 * ref / dt * 100, 10))
        #expect(ours / dt > 0.3)
    }

    @Test func bench() throws {
        let sensor = ProcessTableSensor()
        try sensor.prepare()
        _ = try sensor.sample(SampleContext())
        var ns: [UInt64] = []
        var count = 0
        for _ in 0..<30 {
            let t0 = w6aUptimeNs()
            count = try sensor.sample(SampleContext()).reading.processes.count
            ns.append(w6aUptimeNs() - t0)
        }
        print("W6a bench processes pids=\(count) \(W6aFixture.percentiles(ns))")
    }
}
