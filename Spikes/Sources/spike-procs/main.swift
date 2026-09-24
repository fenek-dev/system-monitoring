import Foundation
import Darwin
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
