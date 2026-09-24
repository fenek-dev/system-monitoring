import CPrivate
import Darwin
import MonitorModel

// MARK: - Parse layer (pure)

/// ARCHITECTURE §6 sentinel-fill check for the private, unversioned `coalition_resource_usage`.
enum CoalitionLayout {
    static let structSize = MemoryLayout<coalition_resource_usage>.size   // 360 (static-asserted in Coalition.h)
    static let slack = 64
    static let sentinel: UInt8 = 0xA5

    enum Verdict: Equatable {
        case ok
        case badBuffer       // not structSize + slack bytes
        case kernelOverran   // (a) bytes past our size changed: kernel ignored the size we passed
        case kernelShorter   // (b) our last field untouched: kernel's struct is shorter than ours
        case noCPUTime       // (c) cpu_time == 0 on our own (running) coalition
    }

    /// `buffer`: `structSize + slack` bytes, pre-filled with `sentinel`, after one call that passed `structSize`.
    static func validate(_ buffer: [UInt8]) -> Verdict {
        guard buffer.count == structSize + slack else { return .badBuffer }
        if buffer[structSize...].contains(where: { $0 != sentinel }) { return .kernelOverran }
        if buffer[(structSize - 8)..<structSize].allSatisfy({ $0 == sentinel }) { return .kernelShorter }
        if decode(buffer).cpu_time == 0 { return .noCPUTime }
        return .ok
    }

    /// First `structSize` bytes as the C struct (host byte order). Short buffers are zero-padded.
    static func decode(_ buffer: [UInt8]) -> coalition_resource_usage {
        var cru = coalition_resource_usage()
        withUnsafeMutableBytes(of: &cru) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<min(src.count, structSize)]))
            }
        }
        return cru
    }
}

enum CoalitionParser {
    static func usage(id: UInt64, cru: coalition_resource_usage, leaderPID: Int32?, members: [Int32],
                      timebase: MachTimebase) -> CoalitionUsage {
        CoalitionUsage(
            id: id,
            leaderPID: leaderPID,
            memberPIDs: members,
            cpuTimeNs: timebase.nanoseconds(cru.cpu_time),
            energyNJ: cru.energy,
            gpuTimeRaw: cru.gpu_time,          // unknown unit: diagnostics only (ARCHITECTURE §10)
            diskReadBytes: cru.bytesread,
            diskWriteBytes: cru.byteswritten
        )
    }

    /// Resource coalition ids from a `proc_listcoalitions` buffer (whole entries only).
    static func resourceIDs(_ buffer: UnsafeRawBufferPointer) -> [UInt64] {
        let stride = MemoryLayout<procinfo_coalinfo>.stride
        var ids: [UInt64] = []
        ids.reserveCapacity(buffer.count / stride / 2)
        for i in 0..<(buffer.count / stride) {
            let c = buffer.loadUnaligned(fromByteOffset: i * stride, as: procinfo_coalinfo.self)
            if c.coalition_type == UInt32(COALITION_TYPE_RESOURCE) { ids.append(c.coalition_id) }
        }
        return ids
    }
}

/// pid → resource coalition. `lookup` (`PROC_PIDCOALITIONINFO` + start time) runs only for pids not seen before
/// (and retries pids whose lookup failed); exited pids are dropped. The member/leader maps are rebuilt only when
/// the pid set changes. A pid reused between two ticks keeps its old coalition (pids are allocated sequentially up
/// to 99 999, so this needs ~100k spawns within one interval).
///
/// Leader heuristic: the **earliest-started live member** (tie → lower pid), i.e. the process the coalition was
/// created for (an app launched by launchd starts before its helpers). The kernel exposes no leader query.
struct CoalitionMembership {
    struct Info: Sendable, Equatable {
        var coalition: UInt64
        var startTimeUs: UInt64
    }

    private var byPID: [Int32: Info] = [:]
    private var lastPIDs: [Int32] = []
    private var unresolved: [Int32] = []
    private(set) var members: [UInt64: [Int32]] = [:]
    private var leaders: [UInt64: Int32] = [:]
    /// Number of map rebuilds (tests/bench).
    private(set) var rebuilds = 0

    var trackedCount: Int { byPID.count }

    func leader(of coalition: UInt64) -> Int32? { leaders[coalition] }

    mutating func update(pids: [Int32], lookup: (Int32) -> Info?) {
        let sorted = pids.sorted()
        if sorted == lastPIDs {
            guard !unresolved.isEmpty else { return }
            var resolvedAny = false
            unresolved.removeAll { pid in
                guard let info = lookup(pid) else { return false }
                byPID[pid] = info
                resolvedAny = true
                return true
            }
            guard resolvedAny else { return }
        } else {
            var next: [Int32: Info] = [:]
            next.reserveCapacity(sorted.count)
            unresolved.removeAll(keepingCapacity: true)
            for pid in sorted {
                if let info = byPID[pid] ?? lookup(pid) {
                    next[pid] = info
                } else {
                    unresolved.append(pid)
                }
            }
            byPID = next          // drops exited pids, whatever the lookup outcomes were
            lastPIDs = sorted
        }
        rebuildMaps()
    }

    private mutating func rebuildMaps() {
        rebuilds += 1
        members.removeAll(keepingCapacity: true)
        leaders.removeAll(keepingCapacity: true)
        var leaderStart: [UInt64: UInt64] = [:]
        for pid in lastPIDs {                     // ascending: ties on start time keep the lower pid
            guard let info = byPID[pid] else { continue }
            members[info.coalition, default: []].append(pid)
            if let cur = leaderStart[info.coalition], cur <= info.startTimeUs { continue }
            leaderStart[info.coalition] = info.startTimeUs
            leaders[info.coalition] = pid
        }
    }
}

// MARK: - FFI layer

enum CoalitionFFI {
    enum Lookup: Equatable {
        case coalition(UInt64)
        case failed(errno: Int32)
        case none          // call succeeded but the pid has no resource coalition (id 0)
    }

    static func lookupCoalition(of pid: Int32) -> Lookup {
        var ci = proc_pidcoalitioninfo()
        let size = Int32(MemoryLayout<proc_pidcoalitioninfo>.size)
        guard proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &ci, size) > 0 else { return .failed(errno: errno) }
        let id = ci.coalition_id.0
        return id == 0 ? .none : .coalition(id)
    }

    static func resourceCoalition(of pid: Int32) -> UInt64? {
        if case .coalition(let id) = lookupCoalition(of: pid) { return id }
        return nil
    }

    /// kinfo `p_starttime` (µs) for one pid; `UInt64.max` (never the leader) when unknown.
    static func startTimeUs(of pid: Int32) -> UInt64 {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.size else { return .max }
        let t = KinfoProcParser.entry(kp).startTimeUs
        return t == 0 ? .max : t
    }

    static func memberInfo(_ pid: Int32) -> CoalitionMembership.Info? {
        guard let c = resourceCoalition(of: pid) else { return nil }
        return .init(coalition: c, startTimeUs: startTimeUs(of: pid))
    }

    /// Sentinel-filled call on `cid` (ARCHITECTURE §6).
    static func sentinelDump(_ cid: UInt64) throws(SensorError) -> [UInt8] {
        var buf = [UInt8](repeating: CoalitionLayout.sentinel, count: CoalitionLayout.structSize + CoalitionLayout.slack)
        let (rc, err) = buf.withUnsafeMutableBytes {
            (coalition_info_resource_usage(cid, $0.baseAddress, CoalitionLayout.structSize), errno)
        }
        guard rc == 0 else { throw w6aErrnoError(err, "coalition_info_resource_usage(\(cid))") }
        return buf
    }
}

// MARK: - Sensor

/// Resource coalitions (private, unprivileged): CPU/energy/disk for every process, root included.
/// Membership: `proc_listallpids` each tick, `PROC_PIDCOALITIONINFO` for new pids only (full pass once in
/// `prepare()`); leader = earliest-started live member (see `CoalitionMembership`).
public final class CoalitionSensor: Sensor {
    public typealias Reading = CoalitionsReading
    public let id = SensorID.coalitions
    public let cadence = SensorCadence.everyTick

    private let timebase = MachTimebase.current
    private var membership = CoalitionMembership()
    private var coalBuffer: [procinfo_coalinfo] = []
    private var pidBuffer: [Int32] = []
    private var prepared = false

    public init() {}

    var membershipRebuilds: Int { membership.rebuilds }

    public func prepare() throws(SensorError) {
        guard !prepared else { return }
        guard tt_coalition_available() else {
            throw SensorError.unavailable("Resource coalitions are not present on this macOS")
        }
        let own: UInt64
        switch CoalitionFFI.lookupCoalition(of: getpid()) {
        case .coalition(let id): own = id
        case .failed(let e): throw w6aErrnoError(e, "PROC_PIDCOALITIONINFO(self)")
        case .none: throw SensorError.unavailable("This process has no resource coalition")
        }
        let dump = try CoalitionFFI.sentinelDump(own)
        guard CoalitionLayout.validate(dump) == .ok else {
            throw SensorError.unavailable("coalition struct layout changed")
        }
        pidBuffer = [Int32](repeating: 0, count: 4096)
        coalBuffer = [procinfo_coalinfo](repeating: procinfo_coalinfo(), count: 2048)
        // Full pass once; start times in bulk from one KERN_PROC_ALL instead of one sysctl per pid.
        let entries = try KinfoProcList().read()
        var starts: [Int32: UInt64] = [:]
        starts.reserveCapacity(entries.count)
        for e in entries where e.startTimeUs != 0 { starts[e.pid] = e.startTimeUs }
        membership = CoalitionMembership()
        membership.update(pids: entries.map(\.pid)) { pid in
            CoalitionFFI.resourceCoalition(of: pid).map {
                .init(coalition: $0, startTimeUs: starts[pid] ?? CoalitionFFI.startTimeUs(of: pid))
            }
        }
        prepared = true
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: CoalitionsReading, capturedNs: UInt64) {
        if !prepared { try prepare() }
        membership.update(pids: try listPIDs(), lookup: CoalitionFFI.memberInfo)
        let ids = try listResourceCoalitions()

        var out: [CoalitionUsage] = []
        out.reserveCapacity(ids.count)
        var cru = coalition_resource_usage()
        let t0 = w6aUptimeNs()
        for cid in ids {
            // Fails (EINVAL/ESRCH) for coalitions that died since the list: skip.
            guard coalition_info_resource_usage(cid, &cru, CoalitionLayout.structSize) == 0 else { continue }
            out.append(CoalitionParser.usage(id: cid, cru: cru, leaderPID: membership.leader(of: cid),
                                             members: membership.members[cid] ?? [], timebase: timebase))
        }
        let t1 = w6aUptimeNs()
        return (CoalitionsReading(coalitions: out), t0 + (t1 - t0) / 2)   // midpoint of the counter reads
    }

    public func invalidate() {
        prepared = false
        membership = CoalitionMembership()
        coalBuffer = []
        pidBuffer = []
    }

    private func listPIDs() throws(SensorError) -> [Int32] {
        for _ in 0..<3 {
            let capacity = pidBuffer.count
            let (n, err) = pidBuffer.withUnsafeMutableBytes {
                (proc_listallpids($0.baseAddress, Int32($0.count)), errno)
            }
            guard n >= 0 else { throw w6aErrnoError(err, "proc_listallpids") }
            if Int(n) < capacity { return Array(pidBuffer[0..<Int(n)]) }
            pidBuffer = [Int32](repeating: 0, count: capacity * 2)
        }
        throw SensorError.transient("proc_listallpids: list kept growing")
    }

    private func listResourceCoalitions() throws(SensorError) -> [UInt64] {
        let stride = MemoryLayout<procinfo_coalinfo>.stride
        for _ in 0..<3 {
            let capacity = coalBuffer.count * stride
            let (bytes, err) = coalBuffer.withUnsafeMutableBytes {
                (proc_listcoalitions(LISTCOALITIONS_ALL_COALS, 0, $0.baseAddress, Int32(capacity)), errno)
            }
            guard bytes >= 0 else { throw w6aErrnoError(err, "proc_listcoalitions") }
            if Int(bytes) < capacity {
                return coalBuffer.withUnsafeBytes {
                    CoalitionParser.resourceIDs(UnsafeRawBufferPointer(rebasing: $0[0..<Int(bytes)]))
                }
            }
            coalBuffer = [procinfo_coalinfo](repeating: procinfo_coalinfo(), count: coalBuffer.count * 2)
        }
        throw SensorError.transient("proc_listcoalitions: list kept growing")
    }
}
