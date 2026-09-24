import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

/// Order (ruling, N6): (1) measured Δ ri_energy_nj (v6) for permitted pids;
/// (2) coalition energy residual for restricted members, same coalition scope and fill/synthetic rules as CoalitionAttributor —
///     skipped entirely when v6 is unavailable (residual would equal the whole coalition → double count with step 3);
/// (3) SoC share (IOReport cpuW × cpu share + gpuW × gpu share) assigned only to pids still without a value.
public protocol EnergyAttributor: Sendable {
    mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?, dt: Double) -> [ProcessID: Double]
    /// Step 3 used this tick → energyEstimated on those rows.
    var usesSoCShareFallback: Bool { get }
}

public struct RulingEnergyAttributor: EnergyAttributor {
    public init() {}
    public mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?, dt: Double) -> [ProcessID: Double] {
        [:]
    }
    public var usesSoCShareFallback: Bool { false }
}
