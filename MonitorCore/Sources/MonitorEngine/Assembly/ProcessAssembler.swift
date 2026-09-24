import Foundation
import MonitorModel

/// Per-process counter deltas over the last interval (session totals, attribution).
struct ProcessDelta: Sendable, Equatable {
    var cpuNs: UInt64 = 0
    var gpuNs: UInt64 = 0
    var rx: UInt64 = 0
    var tx: UInt64 = 0
}

/// The sensor results `ProcessAssembler` consumes for one tick.
struct ProcessInputs {
    var processes: SensorResult<ProcessTableReading>
    var gpuClients: SensorResult<GPUClientsReading> = .notRequested
    var flows: SensorResult<NetworkFlowsReading> = .notRequested
    var rootMemory: SensorResult<RootMemoryReading> = .notRequested
    var assertions: SensorResult<SleepAssertionsReading> = .notRequested
    /// pid → resource coalition id (from the coalitions reading).
    var coalitionOf: [Int32: UInt64] = [:]
    var uptimeNs: UInt64
}

struct ProcessAssembly {
    var samples: [ProcessSample] = []
    var identities: [AppKey: AppIdentity] = [:]
    var identityByPID: [Int32: AppIdentity] = [:]
    var deltas: [ProcessID: ProcessDelta] = [:]
    /// GPU/net that belongs to no live process (→ `.system`).
    var unattributed = UnattributedUsage()
    var unattributedDelta = ProcessDelta()
    /// Seconds covered by the process table's rates (nil on first sight).
    var interval: Double?
}

/// Interval between successive readings of one sensor, by `capturedNs` (same semantics as `RateCalculator`).
struct CaptureClock: Sendable {
    private var last: UInt64?
    private var seconds: Double?

    mutating func advance(to capturedNs: UInt64?) -> Double? {
        guard let capturedNs else { return nil }
        defer { last = capturedNs }
        guard let last else { seconds = nil; return nil }
        if capturedNs == last { return seconds }
        seconds = capturedNs > last ? Double(capturedNs - last) / 1e9 : nil
        return seconds
    }

    mutating func reset() { self = CaptureClock() }
}

/// sysctl list + rusage v6 → `ProcessSample`s; AGX per-client GPU; NStat per `ProcessID`; `ps` RSS for restricted
/// pids; sleep assertions (ARCHITECTURE §3 step 4). Rates go through `RateCalculator`s keyed by `ProcessID`
/// (pid + start time), pruned to the live set every tick.
struct ProcessAssembler {
    private struct GPUClientKey: Hashable, Sendable {
        var clientID: UInt64
        var pid: Int32
        var creator: String
    }

    private enum NetKey: Hashable, Sendable {
        case process(ProcessID)
        case unattributed
    }

    private let currentUID: uid_t
    private var cpu = RateCalculator<ProcessID>()
    private var energy = RateCalculator<ProcessID>()
    private var diskRead = RateCalculator<ProcessID>()
    private var diskWrite = RateCalculator<ProcessID>()
    private var gpu = RateCalculator<GPUClientKey>()
    private var netRx = RateCalculator<NetKey>()
    private var netTx = RateCalculator<NetKey>()
    private var processClock = CaptureClock()
    private var gpuClock = CaptureClock()
    private var netClock = CaptureClock()
    private var userNames: [UInt32: String] = [:]

    init(currentUID: uid_t = getuid()) {
        self.currentUID = currentUID
    }

    var trackedKeyCount: Int {
        cpu.count + energy.count + diskRead.count + diskWrite.count + gpu.count + netRx.count + netTx.count
    }

    mutating func reset() {
        cpu.reset(); energy.reset(); diskRead.reset(); diskWrite.reset(); gpu.reset(); netRx.reset(); netTx.reset()
        processClock.reset(); gpuClock.reset(); netClock.reset()
    }

    mutating func assemble(_ input: ProcessInputs, resolver: any AppResolving) -> ProcessAssembly {
        var out = ProcessAssembly()
        guard let table = input.processes.value, let capturedNs = input.processes.capturedNs else {
            return out
        }
        out.interval = processClock.advance(to: capturedNs)

        let raws = table.processes
        var rawByPID: [Int32: RawProcess] = [:]
        rawByPID.reserveCapacity(raws.count)
        for r in raws { rawByPID[r.id.pid] = r }
        let live = Set(raws.map(\.id))

        out.samples.reserveCapacity(raws.count)
        out.deltas.reserveCapacity(raws.count)
        let rss = input.rootMemory.value?.rssByPID
        let rssAge = input.rootMemory.capturedNs.map { input.uptimeNs >= $0 ? input.uptimeNs - $0 : 0 }
        let assertions = input.assertions.value?.byPID

        for r in raws {
            let responsible = r.responsiblePID.flatMap { $0 == r.id.pid ? nil : rawByPID[$0] }
            let identity = resolver.identity(for: r, responsible: responsible)
            out.identities[identity.key] = identity
            out.identityByPID[r.id.pid] = identity

            var s = ProcessSample(
                id: r.id, name: Self.displayName(r), path: r.path, user: userName(r.uid), uid: r.uid,
                isCurrentUser: r.uid == currentUID, app: identity.key,
                provenance: r.restricted ? .restricted : .measured, coalitionID: input.coalitionOf[r.id.pid],
                cpuTimeNs: r.cpuTimeNs, threads: r.threads,
                diskReadTotal: r.diskReadBytes, diskWriteTotal: r.diskWriteBytes,
                preventsSleep: !(assertions?[r.id.pid]?.isEmpty ?? true))

            if let ns = r.cpuTimeNs, let d = cpu.delta(for: r.id, counter: ns, capturedNs: capturedNs), d.seconds > 0 {
                s.cpuPercent = Double(d.delta) / d.seconds / 1e7
                out.deltas[r.id, default: ProcessDelta()].cpuNs = d.delta
            }
            if let nj = r.energyNJ, let w = energy.rate(for: r.id, counter: nj, capturedNs: capturedNs) {
                s.energyWatts = w / 1e9
            }
            if let b = r.diskReadBytes { s.diskReadBps = diskRead.rate(for: r.id, counter: b, capturedNs: capturedNs) }
            if let b = r.diskWriteBytes { s.diskWriteBps = diskWrite.rate(for: r.id, counter: b, capturedNs: capturedNs) }

            if let fp = r.footprint {
                s.memory = fp
                s.memorySource = .footprint
            } else if r.restricted, let v = rss?[r.id.pid], let age = rssAge {
                s.memory = v
                s.memorySource = .rss(ageNs: age)
            }
            out.samples.append(s)
        }

        var index: [ProcessID: Int] = [:]
        index.reserveCapacity(out.samples.count)
        for (i, s) in out.samples.enumerated() { index[s.id] = i }
        let liveByPID = rawByPID.mapValues(\.id)

        assembleGPU(input.gpuClients, liveByPID: liveByPID, index: index, into: &out)
        assembleNetwork(input.flows, live: live, liveByPID: liveByPID, index: index, into: &out)

        cpu.prune(keeping: live)
        energy.prune(keeping: live)
        diskRead.prune(keeping: live)
        diskWrite.prune(keeping: live)
        resolver.prune(keeping: live)
        return out
    }

    // MARK: - GPU (AGX per client → per pid)

    private mutating func assembleGPU(_ result: SensorResult<GPUClientsReading>, liveByPID: [Int32: ProcessID],
                                      index: [ProcessID: Int], into out: inout ProcessAssembly) {
        guard let reading = result.value, let capturedNs = result.capturedNs else { return }
        let seconds = gpuClock.advance(to: capturedNs)
        var deltaByPID: [Int32: UInt64] = [:]
        var totalByPID: [Int32: UInt64] = [:]
        var keys = Set<GPUClientKey>()
        keys.reserveCapacity(reading.clients.count)
        for c in reading.clients {
            let key = GPUClientKey(clientID: c.clientID, pid: c.pid, creator: c.creatorName)
            keys.insert(key)
            totalByPID[c.pid, default: 0] = Self.saturatingAdd(totalByPID[c.pid] ?? 0, c.gpuTimeNs)
            // first sight / reset / recreated client → no delta: contributes 0 this tick (never a wrapped value)
            if let d = gpu.delta(for: key, counter: c.gpuTimeNs, capturedNs: capturedNs) {
                deltaByPID[c.pid] = Self.saturatingAdd(deltaByPID[c.pid] ?? 0, d.delta)
            }
        }
        gpu.prune(keeping: keys)

        for (pid, total) in totalByPID {
            if let id = liveByPID[pid], let i = index[id] { out.samples[i].gpuTimeNs = total }
        }
        guard let seconds, seconds > 0 else { return }
        for i in out.samples.indices { out.samples[i].gpuPercent = 0 }
        for (pid, delta) in deltaByPID {
            let percent = Double(delta) / seconds / 1e7
            if let id = liveByPID[pid], let i = index[id] {
                out.samples[i].gpuPercent = percent
                out.deltas[id, default: ProcessDelta()].gpuNs = delta
            } else {
                out.unattributed.gpuPercent = (out.unattributed.gpuPercent ?? 0) + percent
                out.unattributedDelta.gpuNs = Self.saturatingAdd(out.unattributedDelta.gpuNs, delta)
            }
        }
    }

    // MARK: - Network (NStat per ProcessID)

    private mutating func assembleNetwork(_ result: SensorResult<NetworkFlowsReading>, live: Set<ProcessID>,
                                          liveByPID: [Int32: ProcessID], index: [ProcessID: Int],
                                          into out: inout ProcessAssembly) {
        guard let reading = result.value, let capturedNs = result.capturedNs else { return }
        let seconds = netClock.advance(to: capturedNs)

        // Cumulative bytes per reported ProcessID (live flows + closed flows) — keyed by the reported id so an
        // exited process's counter simply stops growing (no spike when it becomes unresolvable).
        var cumulative: [ProcessID: ByteCounts] = reading.closedBytes
        var flowCount: [ProcessID: Int] = [:]
        for f in reading.flows {
            var c = cumulative[f.process] ?? ByteCounts()
            c.rx = Self.saturatingAdd(c.rx, f.rxBytes)
            c.tx = Self.saturatingAdd(c.tx, f.txBytes)
            cumulative[f.process] = c
            if let owner = resolve(f.process, live: live, liveByPID: liveByPID) { flowCount[owner, default: 0] += 1 }
        }

        let hasRates = seconds.map { $0 > 0 } ?? false
        if hasRates {
            for i in out.samples.indices {
                out.samples[i].netRxBps = 0
                out.samples[i].netTxBps = 0
            }
        }
        for i in out.samples.indices { out.samples[i].connectionCount = flowCount[out.samples[i].id] ?? 0 }

        var keys = Set<NetKey>([.unattributed])
        keys.reserveCapacity(cumulative.count + 1)
        func account(_ key: NetKey, _ bytes: ByteCounts, owner: ProcessID?, out: inout ProcessAssembly) {
            keys.insert(key)
            if let owner, let i = index[owner] {
                out.samples[i].netRxTotal = Self.saturatingAdd(out.samples[i].netRxTotal ?? 0, bytes.rx)
                out.samples[i].netTxTotal = Self.saturatingAdd(out.samples[i].netTxTotal ?? 0, bytes.tx)
            }
            let rx = netRx.delta(for: key, counter: bytes.rx, capturedNs: capturedNs)
            let tx = netTx.delta(for: key, counter: bytes.tx, capturedNs: capturedNs)
            guard hasRates, let seconds else { return }
            let rxBps = rx.map { Double($0.delta) / seconds }, txBps = tx.map { Double($0.delta) / seconds }
            if let owner, let i = index[owner] {
                if let rxBps { out.samples[i].netRxBps! += rxBps }
                if let txBps { out.samples[i].netTxBps! += txBps }
                out.deltas[owner, default: ProcessDelta()].rx += rx?.delta ?? 0
                out.deltas[owner, default: ProcessDelta()].tx += tx?.delta ?? 0
            } else {
                if let rxBps { out.unattributed.netRxBps = (out.unattributed.netRxBps ?? 0) + rxBps }
                if let txBps { out.unattributed.netTxBps = (out.unattributed.netTxBps ?? 0) + txBps }
                out.unattributedDelta.rx = Self.saturatingAdd(out.unattributedDelta.rx, rx?.delta ?? 0)
                out.unattributedDelta.tx = Self.saturatingAdd(out.unattributedDelta.tx, tx?.delta ?? 0)
            }
        }
        for (pid, bytes) in cumulative {
            account(.process(pid), bytes, owner: resolve(pid, live: live, liveByPID: liveByPID), out: &out)
        }
        account(.unattributed, reading.unattributedBytes, owner: nil, out: &out)

        netRx.prune(keeping: keys)
        netTx.prune(keeping: keys)
    }

    /// `ProcessID(pid, 0)` matches the live process with that pid; else exact match; else nil (→ `.system`).
    private func resolve(_ id: ProcessID, live: Set<ProcessID>, liveByPID: [Int32: ProcessID]) -> ProcessID? {
        if id.startTimeUs == 0 { return liveByPID[id.pid] }
        return live.contains(id) ? id : nil
    }

    // MARK: - Helpers

    /// `proc_name` full name, else the path's basename, else `p_comm`.
    static func displayName(_ r: RawProcess) -> String {
        if let n = r.name, !n.isEmpty { return n }
        if let p = r.path, !p.isEmpty { return (p as NSString).lastPathComponent }
        return r.comm
    }

    private mutating func userName(_ uid: UInt32) -> String? {
        if let hit = userNames[uid] { return hit }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil, let name = pwd.pw_name else {
            return nil
        }
        let s = String(cString: name)
        userNames[uid] = s
        return s
    }

    @inline(__always)
    static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (v, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : v
    }
}
