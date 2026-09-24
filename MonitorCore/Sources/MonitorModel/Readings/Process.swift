import Foundation

/// One row of the process table: sysctl KERN_PROC_ALL is the list (all pids, incl. root);
/// rusage v6 enriches permitted pids.
public struct RawProcess: Sendable, Codable, Hashable {
    /// pid + p_starttime.
    public var id: ProcessID
    public var ppid: Int32, uid: UInt32
    /// p_comm (≤ 16 chars, always available).
    public var comm: String
    /// proc_name full name when permitted.
    public var name: String?
    /// proc_pidpath (nil if EPERM).
    public var path: String?
    public var responsiblePID: Int32?
    /// rusage v6 user+system (mach ticks → ns).
    public var cpuTimeNs: UInt64?
    public var footprint: UInt64?
    public var diskReadBytes: UInt64?, diskWriteBytes: UInt64?
    /// rusage v6 ri_energy_nj (ri_billed_energy is dead: 0).
    public var energyNJ: UInt64?
    public var threads: Int32?
    /// rusage EPERM (~330/920 pids without root).
    public var restricted: Bool

    public init(
        id: ProcessID = ProcessID(),
        ppid: Int32 = 0,
        uid: UInt32 = 0,
        comm: String = "",
        name: String? = nil,
        path: String? = nil,
        responsiblePID: Int32? = nil,
        cpuTimeNs: UInt64? = nil,
        footprint: UInt64? = nil,
        diskReadBytes: UInt64? = nil,
        diskWriteBytes: UInt64? = nil,
        energyNJ: UInt64? = nil,
        threads: Int32? = nil,
        restricted: Bool = false
    ) {
        self.id = id
        self.ppid = ppid
        self.uid = uid
        self.comm = comm
        self.name = name
        self.path = path
        self.responsiblePID = responsiblePID
        self.cpuTimeNs = cpuTimeNs
        self.footprint = footprint
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNJ = energyNJ
        self.threads = threads
        self.restricted = restricted
    }
}

public struct ProcessTableReading: Sendable, Codable {
    public var processes: [RawProcess]

    public init(processes: [RawProcess] = []) {
        self.processes = processes
    }
}
