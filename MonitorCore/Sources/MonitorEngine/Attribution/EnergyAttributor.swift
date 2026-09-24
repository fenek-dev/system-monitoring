import MonitorModel

/// Order (ruling, N6): (1) measured Δ ri_energy_nj (v6) for permitted pids;
/// (2) coalition energy residual for restricted members, same coalition scope and fill/synthetic rules as CoalitionAttributor —
///     skipped entirely when v6 is unavailable (residual would equal the whole coalition → double count with step 3);
/// (3) SoC share (IOReport cpuW × cpu share + gpuW × gpu share) assigned only to pids still without a value.
public protocol EnergyAttributor: Sendable {
    mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?, dt: Double) -> [ProcessID: Double]
    /// Step 3 used this tick → energyEstimated on those rows.
    var usesSoCShareFallback: Bool { get }
}

/// `processes` are the attributed rows of one tick, synthetic coalition rows included. Measured rows carry their
/// v6 watts in `energyWatts` (ProcessAssembler). v6 counts as available when any `.measured` row has a value.
public struct RulingEnergyAttributor: EnergyAttributor {
    public private(set) var usesSoCShareFallback = false

    public init() {}

    public mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?,
                               dt: Double) -> [ProcessID: Double] {
        usesSoCShareFallback = false
        var out: [ProcessID: Double] = [:]
        out.reserveCapacity(processes.count)

        // (1) measured v6
        var v6Available = false
        for p in processes where p.provenance == .measured {
            if let w = p.energyWatts {
                out[p.id] = w
                v6Available = true
            }
        }

        // (2) coalition residual — only coalitions that had a restricted member (rows now .restricted/.coalition)
        if v6Available {
            struct Scope { var visibleWatts = 0.0; var filled: [ProcessID] = []; var restricted = 0; var synthetic: ProcessID? }
            var scopes: [UInt64: Scope] = [:]
            for p in processes {
                guard let cid = p.coalitionID else { continue }
                switch p.provenance {
                case .measured: scopes[cid, default: Scope()].visibleWatts += p.energyWatts ?? 0
                case .restricted: scopes[cid, default: Scope()].restricted += 1
                case .coalition:
                    if p.id.isSynthetic { scopes[cid, default: Scope()].synthetic = p.id } else {
                        scopes[cid, default: Scope()].filled.append(p.id)
                    }
                }
            }
            for (cid, s) in scopes where s.restricted > 0 || !s.filled.isEmpty || s.synthetic != nil {
                guard let coalitionWatts = coalitions.byID[cid]?.watts else { continue }
                let residual = max(0, coalitionWatts - s.visibleWatts)
                if let synthetic = s.synthetic {
                    out[synthetic] = residual
                } else if s.filled.count == 1, s.restricted == 0 {
                    out[s.filled[0]] = residual
                }
            }
        }

        // (3) SoC share for rows still without a value
        guard let soc, soc.cpuWatts != nil || soc.gpuWatts != nil else { return out }
        var cpuTotal = 0.0, gpuTotal = 0.0
        for p in processes {
            cpuTotal += p.cpuPercent ?? 0
            gpuTotal += p.gpuPercent ?? 0
        }
        for p in processes where out[p.id] == nil {
            var w: Double?
            if let cpuW = soc.cpuWatts, let c = p.cpuPercent, cpuTotal > 0 { w = (w ?? 0) + cpuW * c / cpuTotal }
            if let gpuW = soc.gpuWatts, let g = p.gpuPercent, gpuTotal > 0 { w = (w ?? 0) + gpuW * g / gpuTotal }
            if let w {
                out[p.id] = w
                usesSoCShareFallback = true
            }
        }
        return out
    }
}
