import MonitorModel

/// Pure accumulation of NStat sources (no FFI): live flows, bytes of removed flows folded per `ProcessID`
/// (cumulative since sensor start, pruned 10 min after the process exits) and an unattributed bucket for
/// sources retired before their pid was known. No counter is ever subtracted: per-flow counters are clamped
/// monotonic and folds saturate, so a process's live + closed total never decreases.
struct NStatFlowTable: Sendable {
    struct Source: Sendable {
        var process: ProcessID?
        var uniquePID: UInt64?
        var effectivePID: Int32?
        var proto: TransportProtocol = .other
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var endpoints: NStatEndpoints?
    }

    /// Closed-bytes entries of exited processes are dropped this long after the exit is first noticed.
    static let retentionNs: UInt64 = 600_000_000_000

    private var sources: [UInt64: Source] = [:]
    private var closed: [ProcessID: ByteCounts] = [:]
    private var unattributed = ByteCounts()
    /// First uptime at which a closed-only `ProcessID` was seen dead.
    private var deadSince: [ProcessID: UInt64] = [:]
    /// uniqueProcessID → start time (µs; 0 = unknown). uniqueProcessID never repeats within a boot, so this
    /// cache is immune to pid reuse. Bounded by `prune` to the live sources' ids.
    private var startTimes: [UInt64: UInt64] = [:]

    var sourceCount: Int { sources.count }
    var deadSinceCount: Int { deadSince.count }
    var startTimeCacheCount: Int { startTimes.count }
    /// Sources whose pid is still unknown (a description query resolves them).
    var unresolvedCount: Int { sources.values.reduce(0) { $0 + ($1.process == nil ? 1 : 0) } }

    mutating func add(_ id: UInt64) {
        sources[id] = Source()
    }

    /// Applies a description/counts callback. Unknown (already removed) ids are ignored.
    mutating func update(_ id: UInt64, with s: NStatSourceSample, startTime: (Int32) -> UInt64?) {
        guard var src = sources[id] else { return }
        if src.process == nil, let pid = s.pid {
            src.uniquePID = s.uniquePID
            src.process = ProcessID(pid: pid, startTimeUs: resolveStart(pid: pid, uniquePID: s.uniquePID, startTime))
        }
        if let epid = s.effectivePID, epid > 0, epid != src.process?.pid { src.effectivePID = epid }
        if s.proto != .other { src.proto = s.proto }
        if let rx = s.rxBytes { src.rx = max(src.rx, rx) }
        if let tx = s.txBytes { src.tx = max(src.tx, tx) }
        src.endpoints = s.endpoints
        sources[id] = src
    }

    /// Folds the removed source's last-known bytes into its process's closed total (or the unattributed bucket).
    mutating func remove(_ id: UInt64) {
        guard let src = sources.removeValue(forKey: id) else { return }
        guard src.rx > 0 || src.tx > 0 else { return }
        if let p = src.process {
            closed[p] = Self.adding(closed[p] ?? ByteCounts(), src.rx, src.tx)
        } else {
            unattributed = Self.adding(unattributed, src.rx, src.tx)
        }
    }

    func reading(endpoints: Bool, interfaceName: (UInt32) -> String?) -> NetworkFlowsReading {
        var flows: [FlowCounter] = []
        flows.reserveCapacity(sources.count)
        for (id, s) in sources {
            guard let process = s.process else { continue }
            var f = FlowCounter(flowID: id, process: process, effectivePID: s.effectivePID, proto: s.proto,
                                rxBytes: s.rx, txBytes: s.tx)
            if endpoints, let e = s.endpoints {
                f.localPort = e.localPort
                f.remoteAddress = e.remoteAddress
                f.remotePort = e.remotePort
                f.tcpState = e.tcpState
                f.interface = e.interfaceIndex.flatMap(interfaceName)
            }
            flows.append(f)
        }
        flows.sort { $0.flowID < $1.flowID }
        return NetworkFlowsReading(flows: flows, closedBytes: closed, unattributedBytes: unattributed)
    }

    /// Drops closed totals of processes that have been dead for `retentionNs`, and start-time cache entries no
    /// live source needs. `isAlive` is only asked about processes with no live flow.
    mutating func prune(nowNs: UInt64, retentionNs: UInt64 = retentionNs, isAlive: (ProcessID) -> Bool) {
        var live = Set<ProcessID>()
        var liveUniques = Set<UInt64>()
        for s in sources.values {
            if let p = s.process { live.insert(p) }
            if let u = s.uniquePID { liveUniques.insert(u) }
        }
        for key in Array(closed.keys) {
            if live.contains(key) || isAlive(key) {
                deadSince[key] = nil
                continue
            }
            let since = deadSince[key] ?? nowNs
            deadSince[key] = since
            if nowNs >= since, nowNs - since >= retentionNs {
                closed[key] = nil
                deadSince[key] = nil
            }
        }
        startTimes = startTimes.filter { liveUniques.contains($0.key) }
    }

    private mutating func resolveStart(pid: Int32, uniquePID: UInt64?, _ lookup: (Int32) -> UInt64?) -> UInt64 {
        guard let u = uniquePID, u != 0 else { return lookup(pid) ?? 0 }
        if let cached = startTimes[u] { return cached }
        let v = lookup(pid) ?? 0
        startTimes[u] = v
        return v
    }

    private static func adding(_ c: ByteCounts, _ rx: UInt64, _ tx: UInt64) -> ByteCounts {
        let r = c.rx.addingReportingOverflow(rx)
        let t = c.tx.addingReportingOverflow(tx)
        return ByteCounts(rx: r.overflow ? .max : r.partialValue, tx: t.overflow ? .max : t.partialValue)
    }
}
