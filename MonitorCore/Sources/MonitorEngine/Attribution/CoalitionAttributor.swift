import MonitorModel

public struct CoalitionDelta: Sendable, Hashable {
    public var cpuNs: UInt64, energyNJ: UInt64?, diskR: UInt64?, diskW: UInt64?, seconds: Double

    public init(cpuNs: UInt64 = 0, energyNJ: UInt64? = nil, diskR: UInt64? = nil, diskW: UInt64? = nil, seconds: Double = 0) {
        self.cpuNs = cpuNs
        self.energyNJ = energyNJ
        self.diskR = diskR
        self.diskW = diskW
        self.seconds = seconds
    }

    var cpuPercent: Double { seconds > 0 ? Double(cpuNs) / seconds / 1e7 : 0 }
    var watts: Double? { seconds > 0 ? energyNJ.map { Double($0) / seconds / 1e9 } : nil }
    var diskReadBps: Double? { seconds > 0 ? diskR.map { Double($0) / seconds } : nil }
    var diskWriteBps: Double? { seconds > 0 ? diskW.map { Double($0) / seconds } : nil }
}

/// Per coalition, over the coalition reading's own interval.
public struct CoalitionDeltas: Sendable {
    public var byID: [UInt64: CoalitionDelta]
    public var membership: [UInt64: CoalitionUsage]

    public init(byID: [UInt64: CoalitionDelta] = [:], membership: [UInt64: CoalitionUsage] = [:]) {
        self.byID = byID
        self.membership = membership
    }
}

/// Coalition readings → `CoalitionDeltas` through `RateCalculator`s keyed by coalition id.
struct CoalitionTracker: Sendable {
    private var cpu = RateCalculator<UInt64>()
    private var energy = RateCalculator<UInt64>()
    private var diskR = RateCalculator<UInt64>()
    private var diskW = RateCalculator<UInt64>()

    /// nil when the coalitions sensor produced nothing this tick.
    mutating func deltas(_ result: SensorResult<CoalitionsReading>) -> CoalitionDeltas? {
        guard let reading = result.value, let capturedNs = result.capturedNs else { return nil }
        var out = CoalitionDeltas()
        out.byID.reserveCapacity(reading.coalitions.count)
        out.membership.reserveCapacity(reading.coalitions.count)
        var live = Set<UInt64>()
        for c in reading.coalitions {
            live.insert(c.id)
            out.membership[c.id] = c
            let e = c.energyNJ.flatMap { energy.delta(for: c.id, counter: $0, capturedNs: capturedNs) }
            let r = c.diskReadBytes.flatMap { diskR.delta(for: c.id, counter: $0, capturedNs: capturedNs) }
            let w = c.diskWriteBytes.flatMap { diskW.delta(for: c.id, counter: $0, capturedNs: capturedNs) }
            guard let d = cpu.delta(for: c.id, counter: c.cpuTimeNs, capturedNs: capturedNs), d.seconds > 0 else { continue }
            out.byID[c.id] = CoalitionDelta(cpuNs: d.delta, energyNJ: e?.delta, diskR: r?.delta, diskW: w?.delta,
                                            seconds: d.seconds)
        }
        cpu.prune(keeping: live)
        energy.prune(keeping: live)
        diskR.prune(keeping: live)
        diskW.prune(keeping: live)
        return out
    }

    /// pid → coalition id from the reading's membership lists.
    func pidToCoalition(_ result: SensorResult<CoalitionsReading>) -> [Int32: UInt64] {
        guard let reading = result.value else { return [:] }
        var map: [Int32: UInt64] = [:]
        for c in reading.coalitions { for pid in c.memberPIDs { map[pid] = c.id } }
        return map
    }

    mutating func reset() { self = CoalitionTracker() }
}

/// Runs ONLY for coalitions with ≥ 1 member whose provenance is .restricted (all-visible coalitions: rusage wins).
/// residual = Δcoalition − Σ Δvisible members (clamped ≥ 0) for CPU and disk, in rates over each reading's own
/// interval. Exactly one restricted member → it gets the residual (provenance .coalition). Otherwise → one synthetic
/// ProcessSample per coalition (leader p_comm, leader's app; no leader → .system "System"), emitted when the
/// residual passes a threshold (CPU, energy) or any disk residual exists. No GPU: coalition gpu_time has an unknown
/// unit; AGX is the only GPU source. Restricted members get `coalitionLeaderName` (ICR-4).
public struct CoalitionAttributor: Sendable {
    public let minResidualCPUPercent: Double
    public let minResidualWatts: Double

    public init(minResidualCPUPercent: Double = 0.5, minResidualWatts: Double = 0.05) {
        self.minResidualCPUPercent = minResidualCPUPercent
        self.minResidualWatts = minResidualWatts
    }

    public mutating func attribute(_ processes: inout [ProcessSample], coalitions: CoalitionDeltas,
                                   identities: [Int32: AppIdentity]) -> [ProcessSample] {
        var members: [UInt64: [Int]] = [:]
        var restrictedCoalitions = Set<UInt64>()
        var indexByPID: [Int32: Int] = [:]
        indexByPID.reserveCapacity(processes.count)
        for (i, p) in processes.enumerated() {
            if !p.id.isSynthetic { indexByPID[p.pid] = i }
            guard let cid = p.coalitionID else { continue }
            members[cid, default: []].append(i)
            if p.provenance == .restricted { restrictedCoalitions.insert(cid) }
        }

        let energySignificant = RulingEnergyAttributor.v6Available(processes)
        var synthetic: [ProcessSample] = []
        for cid in restrictedCoalitions.sorted() {
            guard let idx = members[cid] else { continue }
            // The leader must be the live process in this coalition (a pid alone could be a reused pid elsewhere).
            let leader = coalitions.membership[cid]?.leaderPID
                .flatMap { indexByPID[$0] }
                .map { processes[$0] }
                .flatMap { $0.coalitionID == cid ? $0 : nil }
            let leaderName = leader?.name
            // Tooltip target, also on ticks without a delta (first tick, coalition sensor cached/failed).
            for i in idx where processes[i].provenance == .restricted { processes[i].coalitionLeaderName = leaderName }
            guard let d = coalitions.byID[cid], d.seconds > 0 else { continue }

            var visCPU = 0.0, visR = 0.0, visW = 0.0, visWatts = 0.0
            var hidden: [Int] = []
            for i in idx {
                let p = processes[i]
                if p.provenance == .restricted {
                    hidden.append(i)
                } else {
                    visCPU += p.cpuPercent ?? 0
                    visR += p.diskReadBps ?? 0
                    visW += p.diskWriteBps ?? 0
                    visWatts += p.energyWatts ?? 0
                }
            }
            let cpu = max(0, d.cpuPercent - visCPU)
            let diskR = d.diskReadBps.map { max(0, $0 - visR) }
            let diskW = d.diskWriteBps.map { max(0, $0 - visW) }

            if hidden.count == 1 {
                let i = hidden[0]
                processes[i].provenance = .coalition
                processes[i].cpuPercent = cpu
                processes[i].diskReadBps = diskR
                processes[i].diskWriteBps = diskW
                continue
            }
            // Energy counts only with v6 (in fallback mode the "residual" would be the whole coalition's energy).
            let watts = energySignificant ? d.watts.map { max(0, $0 - visWatts) } : nil
            let significant = cpu >= minResidualCPUPercent || (watts ?? 0) >= minResidualWatts
                || (diskR ?? 0) > 0 || (diskW ?? 0) > 0
            guard significant else {
                // No residual row to point at: the tooltip names the leader's app instead.
                let appName = leader.flatMap { identities[$0.pid]?.displayName } ?? leaderName
                for i in hidden { processes[i].coalitionLeaderName = appName }
                continue
            }
            let app = leader.flatMap { identities[$0.pid]?.key } ?? (leader?.app ?? .system)
            synthetic.append(ProcessSample(
                id: .coalitionResidual(cid), name: leaderName ?? "System", user: leader?.user, uid: leader?.uid ?? 0,
                isCurrentUser: false, app: leader == nil ? .system : app, provenance: .coalition, coalitionID: cid,
                coalitionLeaderName: leaderName, cpuPercent: cpu, diskReadBps: diskR, diskWriteBps: diskW))
        }
        return synthetic
    }
}
