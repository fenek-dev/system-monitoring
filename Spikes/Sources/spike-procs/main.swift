import Foundation
import Darwin
import AppKit
import CPrivate

struct Sample { var cpuNs: UInt64; var footprint: UInt64; var diskR: UInt64; var diskW: UInt64; var energyNj: UInt64 }

// On Apple Silicon ri_user_time/ri_system_time are mach ticks, not ns.
let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func ticksToNs(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(got, 0))))
}

func rusage(_ pid: pid_t) -> Result<Sample, POSIXError> {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if rc != 0 { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)) }
    return .success(Sample(cpuNs: ticksToNs(info.ri_user_time + info.ri_system_time),
                           footprint: info.ri_phys_footprint,
                           diskR: info.ri_diskio_bytesread, diskW: info.ri_diskio_byteswritten,
                           energyNj: info.ri_billed_energy))
}

func path(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func name(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

var appNameCache: [pid_t: String] = [:]
func appName(owner pid: pid_t) -> String {
    if let c = appNameCache[pid] { return c }
    var n = name(pid)
    if let p = path(pid), let r = p.range(of: ".app/") {
        n = URL(fileURLWithPath: String(p[..<r.lowerBound])).lastPathComponent
    }
    appNameCache[pid] = n
    return n
}

func sweep() -> (ok: [pid_t: Sample], denied: [pid_t], otherErr: Int) {
    var ok: [pid_t: Sample] = [:]; var denied: [pid_t] = []; var other = 0
    for pid in allPids() {
        switch rusage(pid) {
        case .success(let s): ok[pid] = s
        case .failure(let e) where e.code == .EPERM: denied.append(pid)
        case .failure: other += 1
        }
    }
    return (ok, denied, other)
}

// --energy-test: controlled RUSAGE_INFO_V6 vs V4 energy-field probe (fix round 2).
// Not part of the normal sweep; run explicitly to answer "does any per-process
// energy counter move under a known, fixed CPU load".
func rusageV6(_ pid: pid_t) -> rusage_info_v6? {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    return rc == 0 ? info : nil
}

func energyFields(_ i: rusage_info_v6) -> [(String, UInt64)] {
    [
        ("ri_user_time (ticks)", i.ri_user_time),
        ("ri_system_time (ticks)", i.ri_system_time),
        ("ri_user_ptime (P-core ticks)", i.ri_user_ptime),
        ("ri_system_ptime (P-core ticks)", i.ri_system_ptime),
        ("ri_instructions", i.ri_instructions),
        ("ri_cycles", i.ri_cycles),
        ("ri_pinstructions (P-core)", i.ri_pinstructions),
        ("ri_pcycles (P-core)", i.ri_pcycles),
        ("ri_billed_energy (nJ)", i.ri_billed_energy),
        ("ri_serviced_energy (nJ)", i.ri_serviced_energy),
        ("ri_energy_nj", i.ri_energy_nj),
        ("ri_penergy_nj (P-core)", i.ri_penergy_nj),
        ("ri_pkg_idle_wkups", i.ri_pkg_idle_wkups),
    ]
}

func reportDelta(_ label: String, _ a: rusage_info_v6, _ b: rusage_info_v6, dt: Double) {
    print("== \(label) (dt=\(String(format: "%.1f", dt))s) ==")
    for (af, bf) in zip(energyFields(a), energyFields(b)) {
        let delta = bf.1 &- af.1
        print("  \(af.0.padding(toLength: 30, withPad: " ", startingAt: 0)) \(delta)")
    }
}

func firstRunningGUIApp() -> (pid_t, String)? {
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid()
    }
    guard let app = apps.first else { return nil }
    return (app.processIdentifier, app.localizedName ?? "pid \(app.processIdentifier)")
}

func runEnergyTest() {
    // 1. Spin child: `yes >/dev/null &`, sampled over 10s of ~100% CPU on one core.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", "exec yes > /dev/null"]
    do { try proc.run() } catch { print("spin child failed to launch: \(error)"); return }
    Thread.sleep(forTimeInterval: 0.2) // let it ramp up
    if let a = rusageV6(proc.processIdentifier) {
        Thread.sleep(forTimeInterval: 10)
        if let b = rusageV6(proc.processIdentifier) {
            reportDelta("spin child (yes, pid \(proc.processIdentifier))", a, b, dt: 10)
        } else {
            print("spin child: rusage_info_v6 FAILED at t1 (errno=\(errno))")
        }
    } else {
        print("spin child: rusage_info_v6 FAILED at t0 (errno=\(errno))")
    }
    proc.terminate()

    // 2. Self, busy-looping ~10s to pin a core near 100% (own process, so never EPERM).
    let selfPid = getpid()
    if let a = rusageV6(selfPid) {
        let c = ContinuousClock()
        let t0 = c.now
        var sink: UInt64 = 0
        var iters: UInt64 = 0
        while true {
            sink = sink &+ (iters &* 2_654_435_761)
            iters &+= 1
            if iters & 0xFFFFF == 0, c.now - t0 >= .seconds(10) { break }
        }
        if let b = rusageV6(selfPid) {
            reportDelta("self busy-loop (pid \(selfPid), sink=\(sink))", a, b, dt: 10)
        } else {
            print("self: rusage_info_v6 FAILED at t1 (errno=\(errno))")
        }
    } else {
        print("self: rusage_info_v6 FAILED at t0 (errno=\(errno))")
    }

    // 3. A running GUI app (bundled .app), sampled idle over the same window.
    if let (guiPid, guiName) = firstRunningGUIApp() {
        if let a = rusageV6(guiPid) {
            Thread.sleep(forTimeInterval: 10)
            if let b = rusageV6(guiPid) {
                reportDelta("GUI app \(guiName) (pid \(guiPid), idle)", a, b, dt: 10)
            } else {
                print("\(guiName): rusage_info_v6 FAILED at t1 (errno=\(errno))")
            }
        } else {
            print("\(guiName): rusage_info_v6 FAILED at t0 (errno=\(errno))")
        }
    } else {
        print("no running regular (NSWorkspace .activationPolicy == .regular) GUI app found")
    }
}

if CommandLine.arguments.contains("--energy-test") {
    runEnergyTest()
    exit(0)
}

let clock = ContinuousClock()
var first: (ok: [pid_t: Sample], denied: [pid_t], otherErr: Int)!
let sweepCost = clock.measure { first = sweep() }
let t0 = Date()
Thread.sleep(forTimeInterval: 2)
let second = sweep()
let dt = Date().timeIntervalSince(t0)

print("pids ok=\(first.ok.count) EPERM=\(first.denied.count) other=\(first.otherErr) sweep=\(sweepCost)")
print("EPERM sample:", first.denied.prefix(12).map { "\($0):\(name($0))" }.joined(separator: ", "))

struct Agg { var cpu = 0.0; var watts = 0.0; var mem: UInt64 = 0; var diskBps = 0.0; var procs = 0 }
var apps: [String: Agg] = [:]
var respFail = 0
for (pid, b) in second.ok {
    guard let a = first.ok[pid] else { continue }
    let resp = responsibility_get_pid_responsible_for_pid(pid)
    if resp <= 0 { respFail += 1 }
    let key = appName(owner: resp > 0 ? resp : pid)
    var g = apps[key, default: Agg()]
    g.cpu += Double(b.cpuNs &- a.cpuNs) / (dt * 1e9) * 100
    g.watts += Double(b.energyNj &- a.energyNj) / (dt * 1e9)
    g.mem += b.footprint
    g.diskBps += Double((b.diskR &- a.diskR) &+ (b.diskW &- a.diskW)) / dt
    g.procs += 1
    apps[key] = g
}
print("apps=\(apps.count) responsibleFail=\(respFail)")
func row(_ k: String, _ v: String) -> String { k.padding(toLength: 34, withPad: " ", startingAt: 0) + v }
print("-- top CPU (%)");      for (k, v) in apps.sorted(by: { $0.value.cpu > $1.value.cpu }).prefix(10) { print(row(k, String(format: "%6.1f  procs=%d", v.cpu, v.procs))) }
print("-- top energy (W)");   for (k, v) in apps.sorted(by: { $0.value.watts > $1.value.watts }).prefix(5) { print(row(k, String(format: "%6.2f", v.watts))) }
print("-- top footprint (MB)"); for (k, v) in apps.sorted(by: { $0.value.mem > $1.value.mem }).prefix(5) { print(row(k, String(format: "%8.0f", Double(v.mem) / 1_048_576))) }
print("-- top disk (KB/s)");  for (k, v) in apps.sorted(by: { $0.value.diskBps > $1.value.diskBps }).prefix(5) { print(row(k, String(format: "%8.0f", v.diskBps / 1024))) }
