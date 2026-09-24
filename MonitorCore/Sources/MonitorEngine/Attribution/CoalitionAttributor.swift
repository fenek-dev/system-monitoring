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

    /// Membership of the previous fresh/cached reading (one tick of memory, see `pidToCoalition`).
    private var previousMembership: [Int32: UInt64] = [:]

    /// pid → coalition id from the reading's membership lists (`current`), plus `sticky`: members of the previous
    /// reading missing from this one. A member that exited between the process-table read and the coalition read is
    /// still in the process list (its Δ counted) and in the coalition's Δ — without its coalition it wouldn't be
    /// subtracted from the residual and would count twice (ICR-13 "Exited processes", seen as Σ apps 119 % of
    /// system). Kept as a separate small map (not merged into ~600 entries). A missing or failed (stale) reading
    /// clears the memory, so an old map never merges in after a gap.
    mutating func pidToCoalition(_ result: SensorResult<CoalitionsReading>)
        -> (current: [Int32: UInt64], sticky: [Int32: UInt64]) {
        let reading: CoalitionsReading
        switch result {
        case .fresh(let r, _), .cached(let r, _): reading = r
        case .failed(_, let last, _):
            previousMembership = [:]
            guard let last else { return ([:], [:]) }
            reading = last
        case .notRequested:
            previousMembership = [:]
            return ([:], [:])
        }
        var map: [Int32: UInt64] = [:]
        for c in reading.coalitions { for pid in c.memberPIDs { map[pid] = c.id } }
        var sticky: [Int32: UInt64] = [:]
        for (pid, cid) in previousMembership where map[pid] == nil { sticky[pid] = cid }
        if case .failed = result {} else { previousMembership = map }
        return (map, sticky)
    }

    mutating func reset() { self = CoalitionTracker() }
}

/// Runs ONLY for coalitions with ≥ 1 member whose provenance is .restricted (all-visible coalitions: rusage wins).
/// residual = Δcoalition − Σ Δvisible members (clamped ≥ 0) for CPU and disk, in rates over each reading's own
/// interval. Exactly one restricted member → it gets the residual (provenance .coalition). Otherwise → one synthetic
/// ProcessSample per coalition (leader p_comm, leader's app; no leader → .system "System"), emitted when the
/// residual passes a threshold (CPU, energy) or any disk residual exists. No GPU: coalition gpu_time has an unknown
/// unit; AGX is the only GPU source.
///
/// `ProcessSample.coalitionLeaderName` (ICR-4) on restricted members names the tooltip target
/// "counted in the ‹name› coalition row": normally the leader's process name (= the residual row's name); when the
/// residual is below the thresholds and no residual row exists, the leader's **app** display name instead.
/// Session deltas: the frame assembler adds residual-row CPU only when the coalition reading advanced
/// (`CoalitionDeltas` reuse the previous delta for a cached reading, like `RateCalculator`).
///
/// ICR-13 — all-visible coalitions: rusage wins, except that a positive CPU residual above BOTH
/// `minExitedCPUPercent` (of one core) and `minExitedShare` of the coalition's Δ becomes one synthetic
/// "Exited processes" row (`ProcessID.exitedResidual`) in the leader's app (provenance `.coalition`, CPU + disk
/// residuals; energy through `EnergyAttributor` step 2, estimated). That is the CPU of members that started and/or
/// exited between two ticks — invisible to per-pid rusage. Below the thresholds (the ~1 % meter disagreement) nothing
/// changes. Note (as spec'd): the row's energy is coalition W − Σ v6 W, so it also carries the coalition-vs-v6 meter
/// bias (~20 %) — hence estimated.
public struct CoalitionAttributor: Sendable {
    public let minResidualCPUPercent: Double
    public let minResidualWatts: Double
    public let minExitedCPUPercent: Double
    public let minExitedShare: Double

    public init(minResidualCPUPercent: Double = 0.5, minResidualWatts: Double = 0.05,
                minExitedCPUPercent: Double = 5, minExitedShare: Double = 0.10) {
        self.minResidualCPUPercent = minResidualCPUPercent
        self.minResidualWatts = minResidualWatts
        self.minExitedCPUPercent = minExitedCPUPercent
        self.minExitedShare = minExitedShare
    }

    static let exitedRowName = "Exited processes"

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

        // ICR-13: all-visible coalitions → "Exited processes" row when the residual is clearly not meter noise.
        for cid in members.keys.sorted() where !restrictedCoalitions.contains(cid) {
            guard let idx = members[cid], let d = coalitions.byID[cid], d.seconds > 0 else { continue }
            var visCPU = 0.0, visR = 0.0, visW = 0.0
            for i in idx {
                visCPU += processes[i].cpuPercent ?? 0
                visR += processes[i].diskReadBps ?? 0
                visW += processes[i].diskWriteBps ?? 0
            }
            let cpu = d.cpuPercent - visCPU
            guard cpu > minExitedCPUPercent, cpu > minExitedShare * d.cpuPercent else { continue }
            let leader = coalitions.membership[cid]?.leaderPID
                .flatMap { indexByPID[$0] }
                .map { processes[$0] }
                .flatMap { $0.coalitionID == cid ? $0 : nil }
            // No live leader → the member with the lowest pid (independent of process-table order).
            guard let owner = leader ?? idx.map({ processes[$0] }).min(by: { $0.pid < $1.pid }) else { continue }
            synthetic.append(ProcessSample(
                id: .exitedResidual(cid), name: Self.exitedRowName, user: owner.user, uid: owner.uid,
                isCurrentUser: owner.isCurrentUser, app: identities[owner.pid]?.key ?? owner.app, provenance: .coalition,
                coalitionID: cid, coalitionLeaderName: leader?.name, cpuPercent: cpu,
                diskReadBps: d.diskReadBps.map { max(0, $0 - visR) }, diskWriteBps: d.diskWriteBps.map { max(0, $0 - visW) }))
        }
        return synthetic
    }
}
