import Foundation

/// Resource coalition usage (private API, no root): CPU/energy/disk for root processes.
public struct CoalitionUsage: Sendable, Codable, Hashable {
    public var id: UInt64
    public var leaderPID: Int32?
    /// Via proc_pidinfo(PROC_PIDCOALITIONINFO).
    public var memberPIDs: [Int32]
    /// Mach ticks → ns.
    public var cpuTimeNs: UInt64
    /// Energy field per findings (energy[11]).
    public var energyNJ: UInt64?
    /// gpu_time [8]: unknown unit — recorded for diagnostics, never used.
    public var gpuTimeRaw: UInt64?
    public var diskReadBytes: UInt64?, diskWriteBytes: UInt64?

    public init(
        id: UInt64 = 0,
        leaderPID: Int32? = nil,
        memberPIDs: [Int32] = [],
        cpuTimeNs: UInt64 = 0,
        energyNJ: UInt64? = nil,
        gpuTimeRaw: UInt64? = nil,
        diskReadBytes: UInt64? = nil,
        diskWriteBytes: UInt64? = nil
    ) {
        self.id = id
        self.leaderPID = leaderPID
        self.memberPIDs = memberPIDs
        self.cpuTimeNs = cpuTimeNs
        self.energyNJ = energyNJ
        self.gpuTimeRaw = gpuTimeRaw
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }
}

public struct CoalitionsReading: Sendable, Codable {
    public var coalitions: [CoalitionUsage]

    public init(coalitions: [CoalitionUsage] = []) {
        self.coalitions = coalitions
    }
}
