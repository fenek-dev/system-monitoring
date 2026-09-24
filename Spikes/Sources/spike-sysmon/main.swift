import Foundation
import CPrivate
import Darwin

// Question: can an unprivileged, un-entitled process read CPU time and memory of
// root-owned processes (kernel_task, launchd, WindowServer, mds_stores)?
// A. libsysmon/sysmond  B. per-pid kernel APIs  C. resource coalitions

setvbuf(stdout, nil, _IOLBF, 0) // keep output if a private call traps
let me = getpid()
var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func ticksToNs(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) }

// MARK: - A. libsysmon

func describe(_ v: xpc_object_t) -> String {
    let d = xpc_copy_description(v)
    defer { free(d) }
    return String(cString: d)
}

struct Reply { var rows: [[UInt32: String]] = []; var error: String?; var ms = 0.0 }

/// Bitmap sizes read from libsysmon (__sysmonVersionNumber+24): 10, 5, 2 bytes.
/// Any other type traps inside sysmon_request_add_attribute.
let attrLimit: [UInt8: UInt32] = [1: 80, 2: 40, 3: 16]

/// Runs one request. nil = no reply before timeout.
func run(type: UInt8, attrs: [UInt32], timeout: Double = 3) -> Reply? {
    let sem = DispatchSemaphore(value: 0)
    var reply = Reply()
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard let req = sysmon_request_create_with_error(type, { table, err in
        defer { sem.signal() }
        reply.ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if let err { reply.error = String(cString: err) }
        guard let table else { return }
        for i in 0..<sysmon_table_get_count(table) {
            guard let row = sysmon_table_get_row(table, i) else { continue }
            var r: [UInt32: String] = [:]
            sysmon_row_apply(row) { attr, value in
                if let value { r[attr] = describe(value) }
                return true
            }
            reply.rows.append(r)
        }
    }) else { print("type \(type): create returned NULL"); return nil }
    for a in attrs { sysmon_request_add_attribute(req, a) }
    sysmon_request_execute(req)
    let ok = sem.wait(timeout: .now() + timeout) == .success
    sysmon_release(req)
    return ok ? reply : nil
}

print("== A. libsysmon (unentitled)")
for type in UInt8(1)...UInt8(3) {
    guard let r = run(type: type, attrs: Array(0..<attrLimit[type]!)) else {
        print("type \(type): no reply (timeout)"); continue
    }
    print("type \(type): rows=\(r.rows.count) latency=\(String(format: "%.1f", r.ms))ms error=\(r.error ?? "nil")")
    if let mine = r.rows.first(where: { $0.values.contains { $0.hasSuffix(": \(me)") } }) {
        print("  own-pid row:")
        for (k, v) in mine.sorted(by: { $0.key < $1.key }) { print("   [\(k)] \(v.prefix(90))") }
    }
    for probe in ["kernel_task", "WindowServer", "mds_stores"] {
        let hit = r.rows.first { $0.values.contains { $0.contains(probe) } }
        print("  \(probe): \(hit.map { "found, \($0.count) attrs" } ?? "absent")")
    }
}

// MARK: - B. per-pid kernel APIs

func allProcs() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    sysctl(&mib, 4, nil, &size, nil, 0)
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { perror("sysctl"); return [] }
    return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
}

func comm(_ kp: kinfo_proc) -> String {
    withUnsafeBytes(of: kp.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

let procs = allProcs()
let pids = procs.map { $0.kp_proc.p_pid }
let names = Dictionary(procs.map { ($0.kp_proc.p_pid, comm($0)) }, uniquingKeysWith: { a, _ in a })
let uids = Dictionary(procs.map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ucred.cr_uid) }, uniquingKeysWith: { a, _ in a })
let myUid = getuid()
let foreign = pids.filter { uids[$0] != myUid }
print("\n== B. per-pid APIs  (pids=\(pids.count), not-my-uid=\(foreign.count), sysctl names for all: \(names.values.filter { !$0.isEmpty }.count))")

func probe(_ name: String) -> pid_t? { names.first { $0.value == name }?.key }
let probes: [(String, pid_t)] = [("kernel_task", 0), ("launchd", 1)]
    + ["WindowServer", "mds_stores"].compactMap { n in probe(n).map { (n, $0) } }
    + [("self", me)]

/// Each check returns nil on success or the errno.
typealias Check = (pid_t) -> (Int32?, String)

let checks: [(String, Check)] = [
    ("proc_pid_rusage", { pid in
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? (nil, "cpu=\(Int(ticksToNs(ri.ri_user_time + ri.ri_system_time) / 1e6))ms fp=\(ri.ri_phys_footprint >> 20)MB")
                       : (errno, "")
    }),
    ("PROC_PIDTASKINFO", { pid in
        var ti = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return n == Int32(MemoryLayout<proc_taskinfo>.size)
            ? (nil, "cpu=\(Int(ticksToNs(ti.pti_total_user + ti.pti_total_system) / 1e6))ms rss=\(ti.pti_resident_size >> 20)MB")
            : (errno, "")
    }),
    ("PROC_PIDTBSDINFO", { pid in
        var bi = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 ? (nil, "") : (errno, "")
    }),
    ("PROC_PIDT_SHORTBSDINFO", { pid in
        var si = proc_bsdshortinfo()
        let n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        return n > 0 ? (nil, "uid=\(si.pbsi_uid)") : (errno, "")
    }),
    ("proc_pidpath", { pid in
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? (nil, String(cString: buf).split(separator: "/").last.map(String.init) ?? "") : (errno, "")
    }),
    ("PROC_PIDCOALITIONINFO", { pid in
        var ci = proc_pidcoalitioninfo()
        let n = proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &ci, Int32(MemoryLayout<proc_pidcoalitioninfo>.size))
        return n > 0 ? (nil, "rcoal=\(ci.coalition_id.0) jcoal=\(ci.coalition_id.1)") : (errno, "")
    }),
    ("task_name_for_pid+TASK_VM_INFO", { pid in
        var port: mach_port_name_t = 0
        let kr = task_name_for_pid(mach_task_self_, pid, &port)
        guard kr == KERN_SUCCESS else { return (Int32(kr) + 10000, "kr=\(kr)") } // kr, offset to tell apart from errno
        defer { mach_port_deallocate(mach_task_self_, port) }
        var vm = task_vm_info_data_t()
        var cnt = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { task_info(port, task_flavor_t(TASK_VM_INFO), $0, &cnt) }
        }
        return kr2 == KERN_SUCCESS ? (nil, "fp=\(vm.phys_footprint >> 20)MB") : (Int32(kr2) + 20000, "task_info kr=\(kr2)")
    }),
]

for (name, check) in checks {
    var ok = 0, eperm = 0, other: [Int32: Int] = [:], okForeign = 0
    for pid in pids {
        let (err, _) = check(pid)
        if err == nil { ok += 1; if uids[pid] != myUid { okForeign += 1 } }
        else if err == EPERM { eperm += 1 }
        else { other[err!, default: 0] += 1 }
    }
    print("\(name): ok=\(ok) (not-my-uid ok=\(okForeign)/\(foreign.count)) EPERM=\(eperm) other=\(other)")
    for (pn, pid) in probes {
        let (err, info) = check(pid)
        print("   \(pn)(\(pid)): \(err == nil ? "ok \(info)" : "fail err=\(err!) \(info)")")
    }
}

// sysctl KERN_PROC_ALL: does kinfo_proc carry CPU ticks for root processes?
do {
    func ticks(_ kp: kinfo_proc) -> (UInt64, UInt64, UInt64, UInt32) {
        (kp.kp_proc.p_uticks, kp.kp_proc.p_sticks, kp.kp_proc.p_rtime.tv_sec == 0 ? 0 : UInt64(kp.kp_proc.p_rtime.tv_sec), kp.kp_proc.p_pctcpu)
    }
    let nonzero = procs.filter { let t = ticks($0); return t.0 != 0 || t.1 != 0 || t.2 != 0 || t.3 != 0 }
    print("sysctl KERN_PROC_ALL: procs with any nonzero p_uticks/p_sticks/p_rtime/p_pctcpu = \(nonzero.count)/\(procs.count)")
    for (pn, pid) in probes {
        guard let kp = procs.first(where: { $0.kp_proc.p_pid == pid }) else { continue }
        let t = ticks(kp)
        print("   \(pn)(\(pid)): uticks=\(t.0) sticks=\(t.1) rtime_s=\(t.2) pctcpu=\(t.3) uid=\(kp.kp_eproc.e_ucred.cr_uid)")
    }
}

// MARK: - C. resource coalitions

print("\n== C. resource coalitions")
var coals = [procinfo_coalinfo](repeating: procinfo_coalinfo(), count: 8192)
let bytes = proc_listcoalitions(LISTCOALITIONS_ALL_COALS, 0, &coals,
                                Int32(coals.count * MemoryLayout<procinfo_coalinfo>.stride))
if bytes < 0 { print("proc_listcoalitions failed errno=\(errno)") }
let coalList = Array(coals.prefix(max(0, Int(bytes)) / MemoryLayout<procinfo_coalinfo>.stride))
let resCoals = coalList.filter { $0.coalition_type == UInt32(COALITION_TYPE_RESOURCE) }
print("proc_listcoalitions: total=\(coalList.count) resource=\(resCoals.count) jetsam=\(coalList.count - resCoals.count)")

// pid -> resource coalition id, via the unprivileged PROC_PIDCOALITIONINFO flavor.
var coalOf: [pid_t: UInt64] = [:]
for pid in pids {
    var ci = proc_pidcoalitioninfo()
    if proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &ci, Int32(MemoryLayout<proc_pidcoalitioninfo>.size)) > 0 {
        coalOf[pid] = ci.coalition_id.0
    }
}
let members = Dictionary(grouping: coalOf.keys, by: { coalOf[$0]! })

// Attribution granularity for not-my-uid pids: coalition CPU is exact for a pid when it is the
// only live member, or when every other member is ours (subtract our proc_pid_rusage values).
do {
    var sole = 0, restMine = 0, shared = 0, noCoal = 0
    for pid in foreign {
        guard let c = coalOf[pid], let m = members[c] else { noCoal += 1; continue }
        let otherForeign = m.filter { $0 != pid && uids[$0] != myUid }
        if m.count == 1 { sole += 1 } else if otherForeign.isEmpty { restMine += 1 } else { shared += 1 }
    }
    let foreignCoals = Set(foreign.compactMap { coalOf[$0] })
    print("not-my-uid pids=\(foreign.count): sole-member coalition=\(sole), others-all-mine=\(restMine), shares with other foreign pids=\(shared), no coalition=\(noCoal); distinct coalitions=\(foreignCoals.count)")
}

let cruWords = 128
func usage(_ cid: UInt64) -> ([UInt64], Int32?) {
    var buf = [UInt64](repeating: 0, count: cruWords)
    let rc = coalition_info_resource_usage(cid, &buf, buf.count * 8)
    return rc == 0 ? (buf, nil) : ([], errno)
}
// How many bytes does the kernel copy out? Fill with a sentinel and find the last overwritten word.
do {
    var buf = [UInt64](repeating: 0xDEAD_BEEF_DEAD_BEEF, count: cruWords)
    _ = coalition_info_resource_usage(coalOf[me] ?? 1, &buf, buf.count * 8)
    let written = (buf.lastIndex { $0 != 0xDEAD_BEEF_DEAD_BEEF } ?? -1) + 1
    print("kernel struct coalition_resource_usage size ≈ \(written * 8) bytes (\(written) words)")
}
var okC = 0, errC: [Int32: Int] = [:]
for c in resCoals { if let e = usage(c.coalition_id).1 { errC[e, default: 0] += 1 } else { okC += 1 } }
print("coalition_info_resource_usage over resource coalitions: ok=\(okC) err=\(errC)")

// Delta over 2 s for the probes' coalitions; ps (setuid root) is the ground truth.
let probeCoals = probes.compactMap { p in coalOf[p.1].map { (p.0, p.1, $0) } }
let s0 = Dictionary(probeCoals.map { ($0.2, usage($0.2).0) }, uniquingKeysWith: { a, _ in a })
let wall0 = DispatchTime.now().uptimeNanoseconds
Thread.sleep(forTimeInterval: 2)
let s1 = Dictionary(probeCoals.map { ($0.2, usage($0.2).0) }, uniquingKeysWith: { a, _ in a })
let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0)
for (pn, pid, cid) in probeCoals {
    guard let a = s0[cid], let b = s1[cid], a.count > 11, b.count > 11 else { print("   \(pn): no usage"); continue }
    let cpuPct = ticksToNs(b[3] &- a[3]) / wall * 100
    let mem = members[cid] ?? []
    let memberNames = mem.prefix(4).map { names[$0] ?? "?" }.joined(separator: ",")
    print("   \(pn)(\(pid)) rcoal=\(cid) members=\(mem.count) [\(memberNames)\(mem.count > 4 ? ",…" : "")]")
    print("      cpu_time total=\(Int(ticksToNs(b[3]) / 1e9))s  cpu%(2s)=\(String(format: "%.1f", cpuPct))  energy=\(b[11])  diskR=\(b[6] >> 20)MB diskW=\(b[7] >> 20)MB  gpu_time=\(b[8])")
    if pn == "WindowServer" {
        let nz = b.enumerated().filter { $0.element != 0 }.map { "[\($0.offset)]=\($0.element)" }
        print("      raw nonzero words: \(nz.joined(separator: " "))")
    }
}
let probePids = probes.map { String($0.1) }.joined(separator: ",")
print("ground truth: ps -o pid=,%cpu=,time=,rss=,comm= -p \(probePids)")
