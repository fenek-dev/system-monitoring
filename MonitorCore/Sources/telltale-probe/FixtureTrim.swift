import Foundation
import MonitorEngine
import MonitorModel

/// `--record --trim-idle`: shrinks a recording (a busy Mac has ~900 processes, ~450 KB per tick) without changing what
/// the engine computes from it. Kept:
/// - coalitions whose counters (CPU, energy, disk) change during the recording;
/// - processes whose counters change; every restricted member and the leader of a kept coalition (the residual goes
///   to them); pids seen by the GPU or network sensors; the responsible process of anything kept (grouping).
/// Dropped rows never change, so their deltas are 0: per-app CPU/energy/disk, coalition residuals and system totals
/// stay exact. What changes: app memory sums and process/app counts (dropped rows are gone).
enum FixtureTrim {
    struct Result {
        var ticks: [RawTick]
        var processes: (kept: Int, total: Int)
        var coalitions: (kept: Int, total: Int)
    }

    static func trimIdle(_ ticks: [RawTick]) -> Result {
        // 1. Which counters move?
        var firstProc: [ProcessID: [UInt64?]] = [:]
        var changedPIDs: Set<Int32> = []
        var allProcs: Set<ProcessID> = []
        var firstCoal: [UInt64: [UInt64?]] = [:]
        var changedCoal: Set<UInt64> = []
        var allCoal: Set<UInt64> = []
        var sensorPIDs: Set<Int32> = []
        for (k, t) in ticks.enumerated() {
            for p in t.processes.value?.processes ?? [] {
                allProcs.insert(p.id)
                let v = [p.cpuTimeNs, p.energyNJ, p.diskReadBytes, p.diskWriteBytes]
                if let f = firstProc[p.id] {
                    if f != v { changedPIDs.insert(p.id.pid) }
                } else {
                    firstProc[p.id] = v
                    // Appears mid-recording with counters: may count in full as a newborn (counter / interval).
                    if k > 0, v.contains(where: { ($0 ?? 0) > 0 }) { changedPIDs.insert(p.id.pid) }
                }
            }
            for c in t.coalitions.value?.coalitions ?? [] {
                allCoal.insert(c.id)
                let v: [UInt64?] = [c.cpuTimeNs, c.energyNJ, c.diskReadBytes, c.diskWriteBytes]
                if let f = firstCoal[c.id] { if f != v { changedCoal.insert(c.id) } } else { firstCoal[c.id] = v }
            }
            for g in t.gpuClients.value?.clients ?? [] { sensorPIDs.insert(g.pid) }
            if let n = t.networkFlows.value {
                for f in n.flows { sensorPIDs.insert(f.process.pid) }
                for id in n.closedBytes.keys { sensorPIDs.insert(id.pid) }
            }
        }

        // 2. Kept pids: changed ∪ sensor-visible ∪ restricted members + leaders of kept coalitions, then responsible.
        var keep = changedPIDs.union(sensorPIDs)
        var restricted: Set<Int32> = []
        var responsible: [Int32: Int32] = [:]
        for t in ticks {
            for p in t.processes.value?.processes ?? [] {
                if p.restricted { restricted.insert(p.id.pid) }
                if let r = p.responsiblePID, r != p.id.pid { responsible[p.id.pid] = r }
            }
            for c in t.coalitions.value?.coalitions ?? [] where changedCoal.contains(c.id) {
                if let l = c.leaderPID { keep.insert(l) }
                keep.formUnion(c.memberPIDs.filter { restricted.contains($0) })
            }
        }
        // restricted is complete only after the first pass over processes; redo membership with it.
        for t in ticks {
            for c in t.coalitions.value?.coalitions ?? [] where changedCoal.contains(c.id) {
                keep.formUnion(c.memberPIDs.filter { restricted.contains($0) })
            }
        }
        var frontier = keep
        while !frontier.isEmpty {
            let next = Set(frontier.compactMap { responsible[$0] }).subtracting(keep)
            keep.formUnion(next)
            frontier = next
        }

        // 3. Rewrite.
        let out = ticks.map { t -> RawTick in
            var t = t
            t.processes = t.processes.mapValue { r in
                ProcessTableReading(processes: r.processes.filter { keep.contains($0.id.pid) })
            }
            t.coalitions = t.coalitions.mapValue { r in
                var r = r
                r.coalitions = r.coalitions.filter { changedCoal.contains($0.id) }.map { c in
                    var c = c
                    c.memberPIDs = c.memberPIDs.filter { keep.contains($0) }
                    return c
                }
                return r
            }
            t.rootMemory = t.rootMemory.mapValue { r in
                var r = r
                r.rssByPID = r.rssByPID.filter { keep.contains($0.key) }
                return r
            }
            return t
        }
        let keptProcs = allProcs.filter { keep.contains($0.pid) }.count
        return Result(ticks: out, processes: (keptProcs, allProcs.count), coalitions: (changedCoal.count, allCoal.count))
    }
}

extension FixtureTrim {
    /// Replays both recordings through fresh `FrameAssembler`s; returns the worst per-tick differences in
    /// per-app CPU % (apps kept in both), Σ app CPU %, system CPU fraction and Σ app watts.
    static func verify(full: [RawTick], trimmed: [RawTick])
        -> (appCPU: Double, sumCPU: Double, systemCPU: Double, sumWatts: Double) {
        var a = FrameAssembler(resolver: BundleAppResolver())
        var b = FrameAssembler(resolver: BundleAppResolver())
        var worst = (appCPU: 0.0, sumCPU: 0.0, systemCPU: 0.0, sumWatts: 0.0)
        for (x, y) in zip(full, trimmed) {
            let fx = a.assemble(x, inspectedApp: nil), fy = b.assemble(y, inspectedApp: nil)
            let cx = Dictionary(fx.apps.map { ($0.identity.key, $0.cpuPercent ?? 0) }, uniquingKeysWith: +)
            for app in fy.apps {
                worst.appCPU = max(worst.appCPU, abs((cx[app.identity.key] ?? 0) - (app.cpuPercent ?? 0)))
            }
            let sumX = fx.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }, sumY = fy.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
            let wX = fx.apps.reduce(0) { $0 + ($1.energyWatts ?? 0) }, wY = fy.apps.reduce(0) { $0 + ($1.energyWatts ?? 0) }
            worst.sumCPU = max(worst.sumCPU, abs(sumX - sumY))
            worst.sumWatts = max(worst.sumWatts, abs(wX - wY))
            worst.systemCPU = max(worst.systemCPU, abs((fx.cpu.usage ?? 0) - (fy.cpu.usage ?? 0)))
        }
        return worst
    }
}

extension SensorResult {
    /// Same case and timestamps, transformed reading.
    func mapValue(_ f: (R) -> R) -> SensorResult<R> {
        switch self {
        case .fresh(let r, let ns): .fresh(f(r), capturedNs: ns)
        case .cached(let r, let ns): .cached(f(r), capturedNs: ns)
        case .failed(let e, let last, let ns): .failed(e, last: last.map(f), capturedNs: ns)
        case .notRequested: .notRequested
        }
    }
}
