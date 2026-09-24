import CPrivate
import Darwin
import MonitorModel

// MARK: - Parse layer (pure)

/// rusage fields the table keeps. CPU is user+system, mach ticks → ns.
struct RusageValues: Sendable, Equatable {
    var cpuTimeNs: UInt64
    var footprint: UInt64
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
    /// `ri_energy_nj` (v6 only). `ri_billed_energy` is dead (always 0, findings/procs.md) and never read.
    var energyNJ: UInt64?

    init(cpuTimeNs: UInt64, footprint: UInt64, diskReadBytes: UInt64, diskWriteBytes: UInt64, energyNJ: UInt64?) {
        self.cpuTimeNs = cpuTimeNs
        self.footprint = footprint
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNJ = energyNJ
    }

    init(v6 ri: rusage_info_v6, timebase: MachTimebase) {
        self.init(
            cpuTimeNs: Self.cpu(ri.ri_user_time, ri.ri_system_time, timebase),
            footprint: ri.ri_phys_footprint,
            diskReadBytes: ri.ri_diskio_bytesread,
            diskWriteBytes: ri.ri_diskio_byteswritten,
            energyNJ: ri.ri_energy_nj
        )
    }

    init(v4 ri: rusage_info_v4, timebase: MachTimebase) {
        self.init(
            cpuTimeNs: Self.cpu(ri.ri_user_time, ri.ri_system_time, timebase),
            footprint: ri.ri_phys_footprint,
            diskReadBytes: ri.ri_diskio_bytesread,
            diskWriteBytes: ri.ri_diskio_byteswritten,
            energyNJ: nil
        )
    }

    private static func cpu(_ user: UInt64, _ system: UInt64, _ tb: MachTimebase) -> UInt64 {
        let (sum, overflow) = user.addingReportingOverflow(system)
        return overflow ? .max : tb.nanoseconds(sum)
    }
}

enum RusageOutcome: Sendable, Equatable {
    case ok(RusageValues)
    /// EPERM: foreign-uid / root process (~330 of ~920 pids unprivileged).
    case denied
    /// ESRCH: exited between the list and the query.
    case gone
    case failed(Int32)
}

/// Per-pid FFI the builder needs; the live implementation is `LiveProcessSource`, tests inject a fake.
protocol ProcessSource {
    func rusage(_ pid: Int32) -> RusageOutcome
    func threadCount(_ pid: Int32) -> Int32?
    func name(_ pid: Int32) -> String?
    func path(_ pid: Int32) -> String?
    func responsiblePID(_ pid: Int32) -> Int32?
}

/// Merges the kinfo list with rusage enrichment. Name/path/responsible PID are resolved once per `ProcessID`
/// (and again after an exec changes `p_comm`); entries for exited processes are pruned every build.
struct ProcessTableBuilder<Source: ProcessSource> {
    struct Identity {
        var comm: String
        var name: String?
        var path: String?
        var responsiblePID: Int32?
    }

    let source: Source
    private var identities: [ProcessID: Identity] = [:]
    private var live: Set<ProcessID> = []

    init(source: Source) { self.source = source }

    var cachedIdentityCount: Int { identities.count }

    mutating func build(_ entries: [KinfoEntry]) -> [RawProcess] {
        var rows: [RawProcess] = []
        rows.reserveCapacity(entries.count)
        live.removeAll(keepingCapacity: true)

        for e in entries {
            let outcome = source.rusage(e.pid)
            if case .gone = outcome { continue }
            let id = e.id
            live.insert(id)

            let identity: Identity
            if let cached = identities[id], cached.comm == e.comm {
                identity = cached
            } else {
                let r = source.responsiblePID(e.pid)
                identity = Identity(comm: e.comm, name: source.name(e.pid), path: source.path(e.pid),
                                    responsiblePID: (r ?? 0) > 0 ? r : nil)
                identities[id] = identity
            }

            var row = RawProcess(id: id, ppid: e.ppid, uid: e.uid, comm: e.comm, name: identity.name,
                                 path: identity.path, responsiblePID: identity.responsiblePID)
            switch outcome {
            case .ok(let v):
                row.cpuTimeNs = v.cpuTimeNs
                row.footprint = v.footprint
                row.diskReadBytes = v.diskReadBytes
                row.diskWriteBytes = v.diskWriteBytes
                row.energyNJ = v.energyNJ
                row.threads = source.threadCount(e.pid)
            case .denied:
                row.restricted = true
            case .gone, .failed:
                break
            }
            rows.append(row)
        }

        if identities.count > live.count {
            identities = identities.filter { live.contains($0.key) }
        }
        return rows
    }
}

// MARK: - FFI layer

struct LiveProcessSource: ProcessSource {
    let timebase: MachTimebase
    let useV6: Bool
    let hasResponsibility: Bool

    func rusage(_ pid: Int32) -> RusageOutcome {
        let rc: Int32
        let values: RusageValues
        if useV6 {
            var ri = rusage_info_v6()
            rc = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            values = RusageValues(v6: ri, timebase: timebase)
        } else {
            var ri = rusage_info_v4()
            rc = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            values = RusageValues(v4: ri, timebase: timebase)
        }
        if rc == 0 { return .ok(values) }
        switch errno {
        case EPERM, EACCES: return .denied
        case ESRCH: return .gone
        case let e: return .failed(e)
        }
    }

    func threadCount(_ pid: Int32) -> Int32? {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size ? ti.pti_threadnum : nil
    }

    func name(_ pid: Int32) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { buf in
            let n = proc_name(pid, buf.baseAddress, UInt32(buf.count))
            guard n > 0 else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: buf.baseAddress, count: Int(min(n, 255))), as: UTF8.self)
        }
    }

    func path(_ pid: Int32) -> String? {
        let cap = 4 * Int(MAXPATHLEN)
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: cap) { buf in
            let n = proc_pidpath(pid, buf.baseAddress, UInt32(cap))
            guard n > 0 else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: buf.baseAddress, count: Int(min(Int(n), cap))), as: UTF8.self)
        }
    }

    func responsiblePID(_ pid: Int32) -> Int32? {
        guard hasResponsibility else { return nil }
        let r = responsibility_get_pid_responsible_for_pid(pid)
        return r > 0 ? r : nil
    }

    /// RUSAGE_INFO_V6 exists on this kernel (probe on our own pid).
    static func supportsV6() -> Bool {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return rc == 0
    }
}

// MARK: - Sensor

/// sysctl KERN_PROC_ALL (all pids, root included) + `proc_pid_rusage` v6 enrichment for permitted pids.
/// EPERM → `restricted` (root/foreign-uid pids; their CPU/energy/disk come from coalitions, memory from `ps`).
public final class ProcessTableSensor: Sensor {
    public typealias Reading = ProcessTableReading
    public let id = SensorID.processes
    public let cadence = SensorCadence.everyTick

    private var list: KinfoProcList?
    private var builder: ProcessTableBuilder<LiveProcessSource>?

    public init() {}

    public func prepare() throws(SensorError) {
        guard builder == nil else { return }
        let source = LiveProcessSource(
            timebase: .current,
            useV6: LiveProcessSource.supportsV6(),
            hasResponsibility: tt_responsibility_available()
        )
        list = KinfoProcList()
        builder = ProcessTableBuilder(source: source)
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: ProcessTableReading, capturedNs: UInt64) {
        if builder == nil { try prepare() }
        guard let list, var b = builder else { throw SensorError.unavailable("process table not prepared") }
        let entries = try list.read()
        let captured = w6aUptimeNs()
        builder = nil   // keep the builder's dictionaries uniquely referenced while mutating
        let rows = b.build(entries)
        builder = b
        return (ProcessTableReading(processes: rows), captured)
    }

    public func invalidate() {
        builder = nil
        list = nil
    }

    /// Diagnostics for the smoke test / report: v6 in use, responsibility symbol present.
    var diagnostics: (v6: Bool, responsibility: Bool)? {
        builder.map { ($0.source.useV6, $0.source.hasResponsibility) }
    }
}
