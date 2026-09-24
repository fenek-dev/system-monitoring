import Foundation
import CPrivate
import Darwin

// All state is touched only on `q` (serial); `dispatchPrecondition` below confirms every NStat
// callback actually lands there. Main thread only sleeps, shells out to `ps`, and q.sync-reads.
let q = DispatchQueue(label: "nstat")
let quick = ProcessInfo.processInfo.environment["NSTAT_QUICK"] != nil // skip the ~3.5 min of long-running checks for fast iteration

struct Src {
    var pid = 0
    var uniquePid: Int64 = 0 // "uniqueProcessID" from the description dict: immune to pid reuse, unlike `pid`.
    var name = "?"
    var provider = "?"
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var remote = "?"
    var local = "?"
    var state = "?"
}
var sources: [UnsafeMutableRawPointer: Src] = [:]
// Bytes folded in from sources that have been removed (connection closed) since the manager
// started, keyed the same way as `sources` grouping below (uniquePid, falling back to pid).
// Without this, a closed connection's final rx/tx simply vanishes from any per-pid total taken
// after it closes -- see "Fix round 1" in docs/findings/nstat.md.
var retired: [Int64: (name: String, rx: UInt64, tx: UInt64)] = [:]
var printedDescKeys = false, printedCountKeys = false, sampleDesc = ""
var lastAddedAt = Date()
var addedCount = 0

func u64(_ d: NSDictionary, _ k: CFString) -> UInt64 { (d[k as String] as? NSNumber)?.uint64Value ?? 0 }

// Description/counts dictionaries use key names we don't have extern symbols for (remote/local
// address, TCP state, unique pid). Discover them at runtime instead of guessing linker symbol names.
func findKey(_ d: NSDictionary, contains needles: [String]) -> String? {
    for k in d.allKeys {
        guard let ks = k as? String else { continue }
        let lower = ks.lowercased()
        if needles.contains(where: { lower.contains($0) }) { return ks }
    }
    return nil
}

// sockaddr (as CFData) -> "ip:port"; passes strings through unchanged.
func decodeAddr(_ v: Any?) -> String {
    guard let v else { return "?" }
    if let s = v as? String { return s.isEmpty ? "?" : s }
    if let data = v as? Data {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String in
            guard raw.count >= 8, let base = raw.baseAddress else { return "?" }
            let family = raw[1] // sa_len at offset 0, sa_family_t at offset 1
            if family == sa_family_t(AF_INET), raw.count >= MemoryLayout<sockaddr_in>.size {
                let sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var addr = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                let port = UInt16(bigEndian: sin.sin_port)
                return port == 0 && ip == "0.0.0.0" ? "-" : "\(ip):\(port)"
            } else if family == sa_family_t(AF_INET6), raw.count >= MemoryLayout<sockaddr_in6>.size {
                let sin6 = base.assumingMemoryBound(to: sockaddr_in6.self).pointee
                var addr = sin6.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                let ip = String(cString: buf)
                let port = UInt16(bigEndian: sin6.sin6_port)
                return "[\(ip)]:\(port)"
            }
            return "data(\(data.count)b,fam=\(family))"
        }
    }
    return "\(v)"
}

// TCP FSM order per <netinet/tcp_fsm.h>.
let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "CLOSE_WAIT",
                 "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

func decodeState(_ d: NSDictionary, _ key: String) -> String? {
    if let n = d[key] as? NSNumber {
        let i = n.intValue
        return (i >= 0 && i < tcpStates.count) ? tcpStates[i] : "state(\(i))"
    }
    if let s = d[key] as? String { return s }
    return nil
}

var printedStateKey = false
func applyExtras(_ src: NStatSourceRef, _ d: NSDictionary) {
    if let rk = findKey(d, contains: ["remote"]) { sources[src]?.remote = decodeAddr(d[rk]) }
    if let lk = findKey(d, contains: ["local"]) { sources[src]?.local = decodeAddr(d[lk]) }
    if let sk = findKey(d, contains: ["state"]), let st = decodeState(d, sk) {
        sources[src]?.state = st
        if !printedStateKey { printedStateKey = true; print("state key found: \(sk) (provider=\(d[kNStatSrcKeyProvider as String] ?? "?"))") }
    }
    if let uk = findKey(d, contains: ["uniqueprocessid"]), let upid = (d[uk] as? NSNumber)?.int64Value {
        sources[src]?.uniquePid = upid
    }
}

guard let mgr = NStatManagerCreate(kCFAllocatorDefault, q, { src, _ in
    dispatchPrecondition(condition: .onQueue(q))
    guard let src else { return }
    lastAddedAt = Date()
    addedCount += 1
    sources[src] = Src()
    NStatSourceSetDescriptionBlock(src) { cf in
        dispatchPrecondition(condition: .onQueue(q))
        guard let d = cf as NSDictionary? else { return }
        if !printedDescKeys { printedDescKeys = true; print("desc keys:", (d.allKeys as? [String] ?? []).sorted().joined(separator: ", ")); sampleDesc = "\(d)" }
        sources[src]?.pid = (d[kNStatSrcKeyPID as String] as? NSNumber)?.intValue ?? 0
        sources[src]?.name = d[kNStatSrcKeyProcessName as String] as? String ?? "?"
        sources[src]?.provider = d[kNStatSrcKeyProvider as String] as? String ?? "?"
        // Newer OSes may put byte counters in the description too.
        if d[kNStatSrcKeyRxBytes as String] != nil { sources[src]?.rx = u64(d, kNStatSrcKeyRxBytes); sources[src]?.tx = u64(d, kNStatSrcKeyTxBytes) }
        applyExtras(src, d)
    }
    NStatSourceSetCountsBlock(src) { cf in
        dispatchPrecondition(condition: .onQueue(q))
        guard let d = cf as NSDictionary? else { return }
        if !printedCountKeys { printedCountKeys = true; print("count keys:", (d.allKeys as? [String] ?? []).sorted().joined(separator: ", ")) }
        sources[src]?.rx = u64(d, kNStatSrcKeyRxBytes)
        sources[src]?.tx = u64(d, kNStatSrcKeyTxBytes)
        applyExtras(src, d) // state can change/appear here too
    }
    NStatSourceSetRemovedBlock(src) {
        dispatchPrecondition(condition: .onQueue(q))
        // Fold this source's last known counters into the retired accumulator *before* dropping
        // it, so its final bytes stay counted. Keyed by uniquePid (falls back to pid) so pid
        // reuse across the run's lifetime can't merge two unrelated processes' totals.
        if let s = sources[src] {
            let key = s.uniquePid != 0 ? s.uniquePid : Int64(s.pid)
            var r = retired[key, default: (name: s.name, rx: 0, tx: 0)]
            r.rx &+= s.rx
            r.tx &+= s.tx
            if r.name == "?" && s.name != "?" { r.name = s.name }
            retired[key] = r
        }
        sources[src] = nil
    }
}) else { print("NStatManagerCreate returned NULL"); exit(1) }

let creationStart = Date()
NStatManagerAddAllTCP(mgr)
NStatManagerAddAllUDP(mgr)

// Manager creation cost: time from creation until the initial "added" callback flood goes
// quiet, i.e. no new source added for `quietWindow`, or `maxWait` elapses.
let quietWindow: TimeInterval = 0.3
let maxWait: TimeInterval = 5.0
while true {
    Thread.sleep(forTimeInterval: 0.05)
    let quietFor = q.sync { Date().timeIntervalSince(lastAddedAt) }
    if quietFor >= quietWindow || Date().timeIntervalSince(creationStart) >= maxWait { break }
}
let settleElapsed = Date().timeIntervalSince(creationStart)
let settledCount = q.sync { addedCount }
print(String(format: "manager creation + initial added-flood settle: %.3fs (%d sources added, quiet=%.1fs). Recommendation: create ONE manager and keep it long-lived for the app's whole run -- do not recreate it per poll.", settleElapsed, settledCount, quietWindow))

// perPid = live (currently attached sources' cumulative counters) + retired (bytes folded in
// when a source closed). Keyed by uniquePid (falls back to pid) -- see `retired` above. This is
// what makes a pid's total monotonic across the run even as individual connections churn.
func perPid() -> [Int64: (pid: Int, name: String, rx: UInt64, tx: UInt64)] {
    q.sync {
        var m: [Int64: (Int, String, UInt64, UInt64)] = [:]
        for s in sources.values {
            let key = s.uniquePid != 0 ? s.uniquePid : Int64(s.pid)
            var e = m[key, default: (s.pid, s.name, 0, 0)]
            e.2 &+= s.rx; e.3 &+= s.tx
            m[key] = e
        }
        for (key, r) in retired {
            var e = m[key, default: (Int(truncatingIfNeeded: key), r.name, 0, 0)]
            e.2 &+= r.rx; e.3 &+= r.tx
            m[key] = e
        }
        return m
    }
}

func perName() -> [String: (rx: UInt64, tx: UInt64)] {
    var byName: [String: (UInt64, UInt64)] = [:]
    for v in perPid().values {
        var e = byName[v.name, default: (0, 0)]
        e.0 &+= v.rx; e.1 &+= v.tx
        byName[v.name] = e
    }
    return byName
}

func snapshotSources() -> [UnsafeMutableRawPointer: Src] { q.sync { sources } }

func query() {
    let g = DispatchGroup()
    g.enter(); NStatManagerQueryAllSourcesDescriptions(mgr) { g.leave() }
    g.enter(); NStatManagerQueryAllSources(mgr) { g.leave() }
    if g.wait(timeout: .now() + 3) == .timedOut { print("query timeout") }
}

// getifaddrs if_data (AF_LINK entries) totals, as a system-wide cross-check of the sum of
// per-app NStat byte counts.
func ifaceTotals() -> (ibytes: UInt64, obytes: UInt64) {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return (0, 0) }
    defer { freeifaddrs(first) }
    var total: (UInt64, UInt64) = (0, 0)
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        let ifa = p.pointee
        if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
            let ifd = data.assumingMemoryBound(to: if_data.self).pointee
            total.0 += UInt64(ifd.ifi_ibytes)
            total.1 += UInt64(ifd.ifi_obytes)
        }
        ptr = ifa.ifa_next
    }
    return total
}

func psField(_ field: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "\(field)=", "-p", "\(getpid())"]
    let pipe = Pipe()
    p.standardOutput = pipe
    do {
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch { return "" }
}
func cpuPercentSelf() -> Double { Double(psField("%cpu")) ?? -1 }
func rssKBSelf() -> Int { Int(psField("rss")) ?? -1 } // ps rss is in KB

let clock = ContinuousClock()
let firstCost = clock.measure { query() }
let a = perPid()
let connA = snapshotSources()
let ifA = ifaceTotals()
Thread.sleep(forTimeInterval: 2)
let queryCost = clock.measure { query() }
let b = perPid()
let connB = snapshotSources()
let ifB = ifaceTotals()

print("sources=\(q.sync { sources.count }) retired=\(q.sync { retired.count }) pids=\(b.count) firstQuery=\(firstCost) query=\(queryCost)")
print("sample desc:\n" + q.sync { sampleDesc }.split(separator: "\n").prefix(30).joined(separator: "\n"))

let rates = b.map { key, v -> (String, Double, Double) in
    let o = a[key] ?? (v.pid, v.name, v.rx, v.tx)
    return ("\(v.name) [\(v.pid)]", Double(v.rx &- o.rx) / 2048, Double(v.tx &- o.tx) / 2048)  // KB/s over 2 s
}.sorted { $0.1 + $0.2 > $1.1 + $1.2 }
print("\ntop per-app rates (live + retired):")
for (n, rx, tx) in rates.prefix(10) {
    print(n.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "↓%8.1f KB/s  ↑%8.1f KB/s", rx, tx))
}
let appSumRxKB = rates.reduce(0.0) { $0 + $1.1 }
let appSumTxKB = rates.reduce(0.0) { $0 + $1.2 }

// Per-connection sample: pid, process, proto, remote ip:port, TCP state, rx/tx rate.
struct ConnRow { var pid: Int; var name: String; var provider: String; var remote: String; var local: String; var state: String; var rxKB: Double; var txKB: Double }
var connRows: [ConnRow] = []
for (key, sB) in connB {
    let sA = connA[key]
    let rx = Double(sB.rx &- (sA?.rx ?? 0)) / 2048
    let tx = Double(sB.tx &- (sA?.tx ?? 0)) / 2048
    connRows.append(ConnRow(pid: sB.pid, name: sB.name, provider: sB.provider, remote: sB.remote, local: sB.local, state: sB.state, rxKB: rx, txKB: tx))
}
connRows.sort { $0.rxKB + $0.txKB > $1.rxKB + $1.txKB }
print("\nsample connections (top 10 by rate):")
for c in connRows.prefix(10) {
    print("pid=\(c.pid) \(c.name) proto=\(c.provider) local=\(c.local) remote=\(c.remote) state=\(c.state)"
          + String(format: " ↓%.1f KB/s ↑%.1f KB/s", c.rxKB, c.txKB))
}

let ifRxKB = Double(ifB.ibytes &- ifA.ibytes) / 2048
let ifTxKB = Double(ifB.obytes &- ifA.obytes) / 2048
print("\ngetifaddrs (all AF_LINK interfaces) over same 2s window: ↓\(String(format: "%.1f", ifRxKB)) KB/s ↑\(String(format: "%.1f", ifTxKB)) KB/s")
print("sum of per-app NStat rates over same window:            ↓\(String(format: "%.1f", appSumRxKB)) KB/s ↑\(String(format: "%.1f", appSumTxKB)) KB/s")

if quick {
    print("\nNSTAT_QUICK set: skipping the 10s idle-CPU and ~3min churn/memory checks.")
    NStatManagerDestroy(mgr)
    exit(0)
}

// Steady-state CPU of this process (manager still installed, no further queries issued) —
// NStat may push added/removed/counts callbacks continuously even without QueryAllSources calls.
print("\nsteady-state CPU (manager idle, no queries) over 10s, sampled via `ps -o %cpu`:")
var cpuSamples: [Double] = []
for i in 1...5 {
    Thread.sleep(forTimeInterval: 2)
    let c = cpuPercentSelf()
    cpuSamples.append(c)
    print("  t+\(i * 2)s: %cpu=\(c)")
}
let avgCPU = cpuSamples.filter { $0 >= 0 }.reduce(0, +) / Double(max(cpuSamples.filter { $0 >= 0 }.count, 1))
print(String(format: "avg %%cpu over 10s idle window: %.2f", avgCPU))

// --- Fix round 1 verification: churn + memory growth -----------------------------------------
// Drive many short-lived connections (new pid each time, closing within ~2s) and confirm two
// things over a long window: (1) removed-source accounting keeps the "curl" bucket's total
// non-decreasing across repeated queries (bytes from closed connections aren't lost), and
// (2) RSS doesn't grow unbounded as thousands of sources are added and retired.
func spawnChurn(seconds: Int) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "end=$((SECONDS+\(seconds))); while [ $SECONDS -lt $end ]; do curl -sI --max-time 2 https://example.com -o /dev/null 2>/dev/null; done"]
    try? p.run()
    return p
}

let totalSeconds = 180
let sampleEvery = 15
print("\nchurn + memory growth: driving short-lived curl connections for ~\(totalSeconds)s, sampling every \(sampleEvery)s...")
let churn = spawnChurn(seconds: totalSeconds)
var lastCurlTotal: UInt64 = 0
var everDecreased = false
for i in 1...(totalSeconds / sampleEvery) {
    Thread.sleep(forTimeInterval: TimeInterval(sampleEvery))
    query()
    let curl = perName()["curl"] ?? (0, 0)
    let total = curl.rx &+ curl.tx
    let decreased = total < lastCurlTotal
    if decreased { everDecreased = true }
    let rss = rssKBSelf()
    let liveCount = q.sync { sources.count }
    let retiredCount = q.sync { retired.count }
    print("  t+\(i * sampleEvery)s: rss=\(rss)KB live=\(liveCount) retired=\(retiredCount) curlTotal=\(total)B (rx=\(curl.rx) tx=\(curl.tx))\(decreased ? " <-- DECREASED" : "")")
    lastCurlTotal = total
}
churn.waitUntilExit()
print(everDecreased ? "curl total DECREASED at least once -- removed-source accounting still losing bytes." : "curl total was monotonic (non-decreasing) across the whole run -- removed-source bytes are retained.")

NStatManagerDestroy(mgr)
