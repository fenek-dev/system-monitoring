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
    /// Tick wall time: dates the process table's capture against `ProcessID.startTimeUs` (processes born within
    /// the interval). nil → no newborn fill-in.
    var wallTime: Date? = nil
}

struct ProcessAssembly {
    var samples: [ProcessSample] = []
    var identities: [AppKey: AppIdentity] = [:]
    var identityByPID: [Int32: AppIdentity] = [:]
    /// Counter deltas of readings that advanced this tick only (a `.cached` reading contributes nothing), so session
    /// totals never count the same interval twice.
    var deltas: [ProcessID: ProcessDelta] = [:]
    /// GPU/net that belongs to no live process (→ `.system`).
    var unattributed = UnattributedUsage()
    var unattributedDelta = ProcessDelta()
    /// Seconds covered by the process table's rates (nil on first sight; the previous value for a cached reading).
    var interval: Double?
    /// The process table's capturedNs advanced this tick (fresh deltas).
    var advanced = false
    /// NStat-reported `ProcessID` → live owner (connections for the inspected app).
    var flowOwners: [ProcessID: ProcessID] = [:]
}

/// Interval between successive readings of one sensor, by `capturedNs` (same semantics as `RateCalculator`).
struct CaptureClock: Sendable {
    private var last: UInt64?
    private var seconds: Double?

    /// `seconds`: interval behind the current rates (kept for a cached reading). `advanced`: capturedNs moved forward,
    /// i.e. this tick's counter deltas are new.
    mutating func advance(to capturedNs: UInt64?) -> (seconds: Double?, advanced: Bool) {
        guard let capturedNs else { return (nil, false) }
        defer { last = capturedNs }
        guard let last else {
            seconds = nil
            return (nil, false)
        }
        if capturedNs == last { return (seconds, false) }
        seconds = capturedNs > last ? Double(capturedNs - last) / 1e9 : nil
        return (seconds, seconds != nil)
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
    /// Wall-clock µs (and uptime capturedNs) of the last process-table capture: a process whose start time is at or
    /// after it was born inside the current interval.
    private var lastCapture: (capturedNs: UInt64, wallUs: UInt64)?
    private var gpuClock = CaptureClock()
    private var netClock = CaptureClock()
    /// NStat `ProcessID(pid, 0)` → the live process it was first matched to. Pins the loose id to that process, so a
    /// later pid reuse doesn't inherit its bytes (closedBytes keep the loose key after the process exits).
    private var looseOwners: [Int32: ProcessID] = [:]
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
        lastCapture = nil
        looseOwners.removeAll()
    }

    mutating func assemble(_ input: ProcessInputs, resolver: any AppResolving) -> ProcessAssembly {
        var out = ProcessAssembly()
        guard let table = input.processes.value, let capturedNs = input.processes.capturedNs else {
            return out
        }
        let clock = processClock.advance(to: capturedNs)
        out.interval = clock.seconds
        out.advanced = clock.advanced

        // Born within this interval: every counter unit accrued since the previous capture, so a first-seen process
        // contributes counter / interval (not nil) — spawn-heavy loads (builds) would otherwise vanish from Σ apps.
        // The interval (not the process's lifetime) is the denominator: rows, Σ apps and records are interval averages.
        var bornAfterUs: UInt64?
        if let wall = input.wallTime {
            let back = input.uptimeNs >= capturedNs ? (input.uptimeNs - capturedNs) / 1_000 : 0
            let wallUs = UInt64(max(0, wall.timeIntervalSince1970 * 1e6))
            let captureWallUs = wallUs >= back ? wallUs - back : 0
            if clock.advanced, let last = lastCapture { bornAfterUs = last.wallUs }
            if lastCapture?.capturedNs != capturedNs { lastCapture = (capturedNs, captureWallUs) }
        }
        let newbornSeconds = clock.advanced ? clock.seconds.flatMap { $0 > 0 ? $0 : nil } : nil

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

            // Newborn: first sight, started at/after the previous capture (seconds = this interval).
            let newborn: Double? = bornAfterUs.flatMap { r.id.startTimeUs >= $0 ? newbornSeconds : nil }
            if let ns = r.cpuTimeNs {
                if let d = cpu.delta(for: r.id, counter: ns, capturedNs: capturedNs) {
                    if d.seconds > 0 {
                        s.cpuPercent = Double(d.delta) / d.seconds / 1e7
                        if clock.advanced { out.deltas[r.id, default: ProcessDelta()].cpuNs = d.delta }
                    }
                } else if let sec = newborn {
                    s.cpuPercent = Double(ns) / sec / 1e7
                    out.deltas[r.id, default: ProcessDelta()].cpuNs = ns
                }
            }
            if let nj = r.energyNJ {
                if let w = energy.rate(for: r.id, counter: nj, capturedNs: capturedNs) {
                    s.energyWatts = w / 1e9
                } else if let sec = newborn {
                    s.energyWatts = Double(nj) / sec / 1e9
                }
            }
            if let b = r.diskReadBytes {
                s.diskReadBps = diskRead.rate(for: r.id, counter: b, capturedNs: capturedNs) ?? newborn.map { Double(b) / $0 }
            }
            if let b = r.diskWriteBytes {
                s.diskWriteBps = diskWrite.rate(for: r.id, counter: b, capturedNs: capturedNs) ?? newborn.map { Double(b) / $0 }
            }

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

        assembleGPU(input.gpuClients, rawByPID: rawByPID, index: index, into: &out)
        assembleNetwork(input.flows, live: live, rawByPID: rawByPID, index: index, into: &out)

        cpu.prune(keeping: live)
        energy.prune(keeping: live)
        diskRead.prune(keeping: live)
        diskWrite.prune(keeping: live)
        resolver.prune(keeping: live)
        return out
    }

    // MARK: - GPU (AGX per client → per pid)

    private mutating func assembleGPU(_ result: SensorResult<GPUClientsReading>, rawByPID: [Int32: RawProcess],
                                      index: [ProcessID: Int], into out: inout ProcessAssembly) {
        guard let reading = result.value, let capturedNs = result.capturedNs else { return }
        let clock = gpuClock.advance(to: capturedNs)
        var deltaByPID: [Int32: UInt64] = [:]
        var totalByPID: [Int32: UInt64] = [:]
        var keys = Set<GPUClientKey>()
        keys.reserveCapacity(reading.clients.count)
        for c in reading.clients {
            let key = GPUClientKey(clientID: c.clientID, pid: c.pid, creator: c.creatorName)
            keys.insert(key)
            totalByPID[c.pid] = Self.saturatingAdd(totalByPID[c.pid] ?? 0, c.gpuTimeNs)
            // first sight / reset / recreated client → no delta: contributes 0 this tick (never a wrapped value)
            if let d = gpu.delta(for: key, counter: c.gpuTimeNs, capturedNs: capturedNs) {
                deltaByPID[c.pid] = Self.saturatingAdd(deltaByPID[c.pid] ?? 0, d.delta)
            }
        }
        gpu.prune(keeping: keys)

        for (pid, total) in totalByPID {
            if let id = rawByPID[pid]?.id, let i = index[id] { out.samples[i].gpuTimeNs = total }
        }
        guard let seconds = clock.seconds, seconds > 0 else { return }
        for i in out.samples.indices { out.samples[i].gpuPercent = 0 }
        for (pid, delta) in deltaByPID {
            let percent = Double(delta) / seconds / 1e7
            if let id = rawByPID[pid]?.id, let i = index[id] {
                out.samples[i].gpuPercent = percent
                if clock.advanced { out.deltas[id, default: ProcessDelta()].gpuNs = delta }
            } else if delta > 0 {
                out.unattributed.gpuPercent = (out.unattributed.gpuPercent ?? 0) + percent
                if clock.advanced { out.unattributedDelta.gpuNs = Self.saturatingAdd(out.unattributedDelta.gpuNs, delta) }
            }
        }
    }

    // MARK: - Network (NStat per ProcessID)

    private mutating func assembleNetwork(_ result: SensorResult<NetworkFlowsReading>, live: Set<ProcessID>,
                                          rawByPID: [Int32: RawProcess], index: [ProcessID: Int],
                                          into out: inout ProcessAssembly) {
        guard let reading = result.value, let capturedNs = result.capturedNs else { return }
        let clock = netClock.advance(to: capturedNs)

        // Cumulative bytes per reported ProcessID (live flows + closed flows) — keyed by the reported id so an
        // exited process's counter simply stops growing (no spike when it becomes unresolvable).
        var cumulative: [ProcessID: ByteCounts] = reading.closedBytes
        for f in reading.flows {
            var c = cumulative[f.process] ?? ByteCounts()
            c.rx = Self.saturatingAdd(c.rx, f.rxBytes)
            c.tx = Self.saturatingAdd(c.tx, f.txBytes)
            cumulative[f.process] = c
        }
        var owners: [ProcessID: ProcessID] = [:]
        owners.reserveCapacity(cumulative.count)
        for id in cumulative.keys {
            if let owner = resolve(id, live: live, rawByPID: rawByPID) { owners[id] = owner }
        }
        looseOwners = looseOwners.filter { cumulative[ProcessID(pid: $0.key, startTimeUs: 0)] != nil }
        out.flowOwners = owners

        var flowCount: [ProcessID: Int] = [:]
        for f in reading.flows { if let owner = owners[f.process] { flowCount[owner, default: 0] += 1 } }

        let seconds = clock.seconds.flatMap { $0 > 0 ? $0 : nil }
        for i in out.samples.indices {
            out.samples[i].connectionCount = flowCount[out.samples[i].id] ?? 0
            if seconds != nil {
                out.samples[i].netRxBps = 0
                out.samples[i].netTxBps = 0
            }
        }

        var keys = Set<NetKey>([.unattributed])
        keys.reserveCapacity(cumulative.count + 1)
        func account(_ key: NetKey, _ bytes: ByteCounts, owner: ProcessID?, out: inout ProcessAssembly) {
            keys.insert(key)
            let slot = owner.flatMap { index[$0] }
            if let i = slot {
                out.samples[i].netRxTotal = Self.saturatingAdd(out.samples[i].netRxTotal ?? 0, bytes.rx)
                out.samples[i].netTxTotal = Self.saturatingAdd(out.samples[i].netTxTotal ?? 0, bytes.tx)
            }
            let rx = netRx.delta(for: key, counter: bytes.rx, capturedNs: capturedNs)
            let tx = netTx.delta(for: key, counter: bytes.tx, capturedNs: capturedNs)
            guard let seconds else { return }
            let rxBps = Double(rx?.delta ?? 0) / seconds, txBps = Double(tx?.delta ?? 0) / seconds
            let delta = ProcessDelta(rx: clock.advanced ? rx?.delta ?? 0 : 0, tx: clock.advanced ? tx?.delta ?? 0 : 0)
            if let i = slot, let owner {
                out.samples[i].netRxBps = (out.samples[i].netRxBps ?? 0) + rxBps
                out.samples[i].netTxBps = (out.samples[i].netTxBps ?? 0) + txBps
                out.deltas[owner, default: ProcessDelta()].accumulate(delta)
            } else {
                // only real traffic creates/grows the System share (no 0 B/s "System" row out of nothing)
                if rxBps > 0 { out.unattributed.netRxBps = (out.unattributed.netRxBps ?? 0) + rxBps }
                if txBps > 0 { out.unattributed.netTxBps = (out.unattributed.netTxBps ?? 0) + txBps }
                out.unattributedDelta.accumulate(delta)
            }
        }
        for (id, bytes) in cumulative { account(.process(id), bytes, owner: owners[id], out: &out) }
        account(.unattributed, reading.unattributedBytes, owner: nil, out: &out)

        netRx.prune(keeping: keys)
        netTx.prune(keeping: keys)
    }

    /// Exact `ProcessID` when live; `ProcessID(pid, 0)` → the live process it was first matched to (pinned, so pid
    /// reuse doesn't inherit it), else the live process with that pid; nil (→ `.system`) otherwise.
    private mutating func resolve(_ id: ProcessID, live: Set<ProcessID>, rawByPID: [Int32: RawProcess]) -> ProcessID? {
        guard id.startTimeUs == 0 else { return live.contains(id) ? id : nil }
        if let pinned = looseOwners[id.pid] { return live.contains(pinned) ? pinned : nil }
        guard let current = rawByPID[id.pid]?.id else { return nil }
        looseOwners[id.pid] = current
        return current
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
