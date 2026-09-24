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

/// pid → resource coalition, via `PROC_PIDCOALITIONINFO` for **new** `ProcessID`s only; exited ones are dropped.
/// Leader = earliest-started live member (tie → lower pid): the process the coalition was created for.
struct CoalitionMembership {
    private var coalitionOf: [ProcessID: UInt64] = [:]
    private var live: Set<ProcessID> = []
    private(set) var members: [UInt64: [Int32]] = [:]
    private var leaders: [UInt64: ProcessID] = [:]

    var trackedCount: Int { coalitionOf.count }

    func leader(of coalition: UInt64) -> Int32? { leaders[coalition]?.pid }

    mutating func update(_ entries: [KinfoEntry], lookup: (Int32) -> UInt64?) {
        live.removeAll(keepingCapacity: true)
        for e in entries {
            let id = e.id
            live.insert(id)
            if coalitionOf[id] == nil, let c = lookup(e.pid) { coalitionOf[id] = c }
        }
        if coalitionOf.count > live.count {
            coalitionOf = coalitionOf.filter { live.contains($0.key) }
        }

        members.removeAll(keepingCapacity: true)
        leaders.removeAll(keepingCapacity: true)
        for (id, c) in coalitionOf {
            members[c, default: []].append(id.pid)
            if let cur = leaders[c] {
                if (id.startTimeUs, id.pid) < (cur.startTimeUs, cur.pid) { leaders[c] = id }
            } else {
                leaders[c] = id
            }
        }
        for c in members.keys { members[c]?.sort() }
    }
}

// MARK: - FFI layer

enum CoalitionFFI {
    static func resourceCoalition(of pid: Int32) -> UInt64? {
        var ci = proc_pidcoalitioninfo()
        let size = Int32(MemoryLayout<proc_pidcoalitioninfo>.size)
        guard proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &ci, size) > 0 else { return nil }
        let id = ci.coalition_id.0
        return id == 0 ? nil : id
    }

    /// Sentinel-filled call on `cid` (ARCHITECTURE §6).
    static func sentinelDump(_ cid: UInt64) throws(SensorError) -> [UInt8] {
        var buf = [UInt8](repeating: CoalitionLayout.sentinel, count: CoalitionLayout.structSize + CoalitionLayout.slack)
        let rc = buf.withUnsafeMutableBytes { coalition_info_resource_usage(cid, $0.baseAddress, CoalitionLayout.structSize) }
        guard rc == 0 else { throw SensorError.fromErrno("coalition_info_resource_usage(\(cid))") }
        return buf
    }
}

// MARK: - Sensor

/// Resource coalitions (private, unprivileged): CPU/energy/disk for every process, root included.
public final class CoalitionSensor: Sensor {
    public typealias Reading = CoalitionsReading
    public let id = SensorID.coalitions
    public let cadence = SensorCadence.everyTick

    private let timebase = MachTimebase.current
    private var list: KinfoProcList?
    private var membership = CoalitionMembership()
    private var coalBuffer: [procinfo_coalinfo] = []
    private var prepared = false

    public init() {}

    public func prepare() throws(SensorError) {
        guard !prepared else { return }
        guard tt_coalition_available() else {
            throw SensorError.unavailable("Resource coalitions are not present on this macOS")
        }
        guard let own = CoalitionFFI.resourceCoalition(of: getpid()) else {
            throw SensorError.fromErrno("PROC_PIDCOALITIONINFO(self)")
        }
        let dump = try CoalitionFFI.sentinelDump(own)
        guard CoalitionLayout.validate(dump) == .ok else {
            throw SensorError.unavailable("coalition struct layout changed")
        }
        let l = KinfoProcList()
        membership = CoalitionMembership()
        membership.update(try l.read(), lookup: CoalitionFFI.resourceCoalition)   // full pass once
        list = l
        coalBuffer = [procinfo_coalinfo](repeating: procinfo_coalinfo(), count: 2048)
        prepared = true
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: CoalitionsReading, capturedNs: UInt64) {
        if !prepared { try prepare() }
        guard let list else { throw SensorError.unavailable("coalitions not prepared") }
        membership.update(try list.read(), lookup: CoalitionFFI.resourceCoalition)
        let ids = try listResourceCoalitions()
        let captured = w6aUptimeNs()

        var out: [CoalitionUsage] = []
        out.reserveCapacity(ids.count)
        var cru = coalition_resource_usage()
        for cid in ids {
            // Fails (EINVAL/ESRCH) for coalitions that died since the list: skip.
            guard coalition_info_resource_usage(cid, &cru, CoalitionLayout.structSize) == 0 else { continue }
            out.append(CoalitionParser.usage(id: cid, cru: cru, leaderPID: membership.leader(of: cid),
                                             members: membership.members[cid] ?? [], timebase: timebase))
        }
        return (CoalitionsReading(coalitions: out), captured)
    }

    public func invalidate() {
        prepared = false
        list = nil
        membership = CoalitionMembership()
        coalBuffer = []
    }

    private func listResourceCoalitions() throws(SensorError) -> [UInt64] {
        let stride = MemoryLayout<procinfo_coalinfo>.stride
        for _ in 0..<3 {
            let capacity = coalBuffer.count * stride
            let bytes = coalBuffer.withUnsafeMutableBytes {
                proc_listcoalitions(LISTCOALITIONS_ALL_COALS, 0, $0.baseAddress, Int32(capacity))
            }
            guard bytes >= 0 else { throw SensorError.fromErrno("proc_listcoalitions") }
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
