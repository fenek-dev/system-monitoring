import MonitorModel

/// Order (ruling, N6): (1) measured Δ ri_energy_nj (v6) for permitted pids;
/// (2) coalition energy residual for restricted members, same coalition scope and fill/synthetic rules as CoalitionAttributor —
///     skipped entirely when v6 is unavailable (residual would equal the whole coalition → double count with step 3);
/// (3) SoC share (IOReport cpuW × cpu share) assigned only to pids still without a value.
/// GPU term (ICR-8: v6 `ri_energy_nj` excludes GPU energy): every row with an AGX GPU share additionally gets
/// IOReport gpuW × its share of the whole GPU (gpuPercent / 100, scaled down if Σ > 100 %); skipped without gpuW.
public protocol EnergyAttributor: Sendable {
    mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?, dt: Double) -> [ProcessID: Double]
    /// Step 3 used this tick → energyEstimated on those rows.
    var usesSoCShareFallback: Bool { get }
    /// Rows whose value from the last `watts` call is an estimate (steps 2 and 3); measured v6 rows are never in it
    /// (ICR-5, additive).
    var estimatedIDs: Set<ProcessID> { get }
}

public extension EnergyAttributor {
    /// Default for attributors without per-row knowledge: nothing flagged.
    var estimatedIDs: Set<ProcessID> { [] }
}

/// `processes` are the attributed rows of one tick, synthetic coalition rows included. Measured rows carry their
/// v6 watts in `energyWatts` (ProcessAssembler). v6 counts as available when any `.measured` row has a value.
public struct RulingEnergyAttributor: EnergyAttributor {
    public private(set) var usesSoCShareFallback = false
    public private(set) var estimatedIDs: Set<ProcessID> = []

    public init() {}

    /// True when any measured row carries a v6 energy value (shared with CoalitionAttributor's significance rule).
    static func v6Available(_ processes: [ProcessSample]) -> Bool {
        processes.contains { $0.provenance == .measured && $0.energyWatts != nil }
    }

    public mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?,
                               dt: Double) -> [ProcessID: Double] {
        usesSoCShareFallback = false
        estimatedIDs.removeAll(keepingCapacity: true)
        var out: [ProcessID: Double] = [:]
        out.reserveCapacity(processes.count)

        // (1) measured v6
        for p in processes where p.provenance == .measured {
            if let w = p.energyWatts { out[p.id] = w }
        }

        // (2) coalition residual — only coalitions that had a restricted member (rows now .restricted/.coalition).
        // Scopes that got a residual are closed for step 3: their energy is fully accounted (a measured member
        // without a v6 value yet is inside the residual).
        var closedScopes = Set<UInt64>()
        if Self.v6Available(processes) {
            struct Scope { var visibleWatts = 0.0; var filled: [ProcessID] = []; var restricted = 0; var synthetic: ProcessID? }
            var scopes: [UInt64: Scope] = [:]
            for p in processes {
                guard let cid = p.coalitionID else { continue }
                switch p.provenance {
                case .measured: scopes[cid, default: Scope()].visibleWatts += p.energyWatts ?? 0
                case .restricted: scopes[cid, default: Scope()].restricted += 1
                case .coalition:
                    if p.id.isSynthetic {
                        scopes[cid, default: Scope()].synthetic = p.id
                    } else {
                        scopes[cid, default: Scope()].filled.append(p.id)
                    }
                }
            }
            for (cid, s) in scopes where s.restricted > 0 || !s.filled.isEmpty || s.synthetic != nil {
                guard let coalitionWatts = coalitions.byID[cid]?.watts else { continue }
                let residual = max(0, coalitionWatts - s.visibleWatts)
                var target: ProcessID?
                if let synthetic = s.synthetic {
                    target = synthetic
                } else if s.filled.count == 1, s.restricted == 0 {
                    target = s.filled[0]
                }
                if let target {
                    out[target] = residual
                    estimatedIDs.insert(target)
                    closedScopes.insert(cid)
                }
            }
        }

        guard let soc else { return out }

        // (3) CPU-side SoC share for rows still without a value, outside closed scopes (GPU is the separate term below)
        if let cpuW = soc.cpuWatts {
            let cpuTotal = processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
            if cpuTotal > 0 {
                for p in processes where out[p.id] == nil {
                    if let cid = p.coalitionID, closedScopes.contains(cid) { continue }
                    guard let c = p.cpuPercent else { continue }
                    out[p.id] = cpuW * c / cpuTotal
                    estimatedIDs.insert(p.id)
                    usesSoCShareFallback = true
                }
            }
        }

        // GPU term (ICR-8), every row with an AGX share, restricted and synthetic rows included
        if let gpuW = soc.gpuWatts {
            let gpuTotal = processes.reduce(0) { $0 + ($1.gpuPercent ?? 0) }
            let scale = 1 / max(100, gpuTotal)                  // shares of the whole GPU; never more than all of it
            for p in processes {
                guard let g = p.gpuPercent, g > 0 else { continue }
                let term = gpuW * g * scale
                let total = (out[p.id] ?? 0) + term
                out[p.id] = total
                if total > 0, term / total > 0.1 { estimatedIDs.insert(p.id) }
            }
        }
        return out
    }
}
