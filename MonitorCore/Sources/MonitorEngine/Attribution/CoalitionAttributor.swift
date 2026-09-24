import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

public struct CoalitionDelta: Sendable, Hashable {
    public var cpuNs: UInt64, energyNJ: UInt64?, diskR: UInt64?, diskW: UInt64?, seconds: Double
}

/// Per coalition, over the coalition reading's own interval.
public struct CoalitionDeltas: Sendable {
    public var byID: [UInt64: CoalitionDelta]
    public var membership: [UInt64: CoalitionUsage]
}

/// Runs ONLY for coalitions with ≥ 1 member whose provenance is .restricted (all-visible coalitions: rusage wins).
/// residual = Δcoalition − Σ Δvisible members (clamped ≥ 0) for CPU and disk.
/// Exactly one restricted member → it gets the residual (provenance .coalition).
/// Otherwise → one synthetic ProcessSample per coalition (leader p_comm, leader's app; no leader → .system "System").
/// No GPU: coalition gpu_time has an unknown unit; AGX is the only GPU source.
public struct CoalitionAttributor: Sendable {
    public init(minResidualCPUPercent: Double = 0.5, minResidualWatts: Double = 0.05) {}
    /// Returns synthetic rows.
    public mutating func attribute(_ processes: inout [ProcessSample], coalitions: CoalitionDeltas,
                                   identities: [Int32: AppIdentity]) -> [ProcessSample] { [] }
}
