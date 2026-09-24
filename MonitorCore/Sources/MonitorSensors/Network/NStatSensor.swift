import CPrivate
import Foundation
import MonitorModel
import os

/// Per-app / per-connection network bytes from the private NetworkStatistics framework (what `nettop` uses).
///
/// One long-lived manager (creation floods ~150 "added" callbacks, 0.3–1.3 s). Every callback runs on the box's
/// serial queue; `sample()` returns the last **completed** query and starts the next one asynchronously
/// (interactive: every tick; background: 10 s). Removed sources get a final description + counts callback from
/// NStat before the removed block, so their bytes are folded into `closedBytes` even between queries.
public final class NStatSensor: Sensor {
    public typealias Reading = NetworkFlowsReading
    public let id: SensorID = .networkFlows
    public let cadence: SensorCadence = SensorCadence(interactive: .zero, background: .seconds(10))

    let box = NStatBox()
    /// Stays here (never in the Sendable box). Created in `prepare()`, destroyed in `invalidate()`.
    private var manager: NStatManagerRef?

    public init() {}

    deinit { invalidate() }

    public func prepare() throws(SensorError) {
        guard manager == nil else { return }
        guard tt_nstat_available() else { throw .unavailable("NetworkStatistics.framework is unavailable") }
        let box = self.box
        guard let m = NStatManagerCreate(kCFAllocatorDefault, box.queue, { src, _ in
            guard let src else { return }
            box.attach(src)
        }) else {
            throw .unavailable("NStatManagerCreate returned NULL")
        }
        NStatManagerAddAllTCP(m)
        NStatManagerAddAllUDP(m)
        manager = m
        startQuery(m)
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: NetworkFlowsReading, capturedNs: UInt64) {
        guard let m = manager else { throw .unavailable("NStat manager not prepared") }
        box.setWantEndpoints(ctx.demand.contains(.connections))
        if let last = box.lastCompleted() {
            startQuery(m)
            return last
        }
        // First sample after prepare(): the initial query is already running; give it ≤ 200 ms.
        startQuery(m)
        _ = box.firstQuery.wait(timeout: .now() + .milliseconds(200))
        guard let last = box.lastCompleted() else { throw .transient("NStat: first query pending") }
        return last
    }

    public func invalidate() {
        guard let m = manager else { return }
        manager = nil
        box.retire() // late completions of this manager's queries are ignored from here on
        NStatManagerDestroy(m)
        let box = self.box
        box.queue.async { box.reset() }
    }

    /// Counts query; plus a descriptions query while any source is unidentified (a counts callback for a
    /// never-described source carries pid 0 and no name).
    private func startQuery(_ m: NStatManagerRef) {
        let box = self.box
        let describe = box.needsDescriptions()
        guard let gen = box.beginQuery(nowNs: W6cClock.uptimeNs(), parts: describe ? 2 : 1) else { return }
        if describe { NStatManagerQueryAllSourcesDescriptions(m) { box.partCompleted(gen) } }
        NStatManagerQueryAllSources(m) { box.partCompleted(gen) }
    }
}

/// Callback-driven NStat state (ARCHITECTURE §4): C blocks capture only this box. No syscall runs under the lock:
/// callbacks read what they need, call sysctl/proc_pidinfo/if_indextoname unlocked, then apply. That is race-free
/// because every mutation happens on the one serial `queue`.
final class NStatBox: Sendable {
    struct State: Sendable {
        var table = NStatFlowTable()
        var keys = NStatKeyMap()
        /// Key re-discovery attempts left (only when a required key is missing).
        var refineBudget = 16
        var wantEndpoints = false
        var nextID: UInt64 = 1
        var last: NetworkFlowsReading?
        var lastCapturedNs: UInt64 = 0
        /// Bumped by every new query and by `retire()`: completions carrying an older generation are ignored.
        var generation: UInt64 = 0
        var queryStartedNs: UInt64?
        var pendingParts = 0
        var lastQueryCostNs: UInt64 = 0
        var lastPruneNs: UInt64 = 0
        var interfaceNames: [UInt32: String] = [:]
        var firstSignalled = false
    }

    /// A query stuck longer than this no longer blocks new ones (the new one supersedes it).
    static let queryStallNs: UInt64 = 5_000_000_000
    static let pruneIntervalNs: UInt64 = 30_000_000_000

    let queue = DispatchQueue(label: "dev.telltale.nstat", qos: .utility)
    let lock = OSAllocatedUnfairLock(initialState: State())
    /// Signalled once, when the first query completes.
    let firstQuery = DispatchSemaphore(value: 0)

    // MARK: sampler side

    func setWantEndpoints(_ want: Bool) {
        lock.withLock { $0.wantEndpoints = want }
    }

    func lastCompleted() -> (reading: NetworkFlowsReading, capturedNs: UInt64)? {
        lock.withLock { s in s.last.map { ($0, s.lastCapturedNs) } }
    }

    /// The new query's generation, or nil while one is in flight (unless it stalled). `parts` = completion
    /// blocks to await.
    func beginQuery(nowNs: UInt64, parts: Int) -> UInt64? {
        lock.withLock { s in
            if let started = s.queryStartedNs, nowNs >= started, nowNs - started < Self.queryStallNs { return nil }
            s.generation += 1
            s.queryStartedNs = nowNs
            s.pendingParts = parts
            return s.generation
        }
    }

    /// Invalidates in-flight queries (manager about to be destroyed).
    func retire() {
        lock.withLock { s in
            s.generation += 1
            s.queryStartedNs = nil
            s.pendingParts = 0
        }
    }

    func needsDescriptions() -> Bool {
        lock.withLock { $0.table.unresolvedCount > 0 }
    }

    var lastQueryCostNs: UInt64 { lock.withLock { $0.lastQueryCostNs } }

    // MARK: callback side (box queue)

    func attach(_ src: NStatSourceRef) {
        assertOnQueue()
        let id = lock.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            s.table.add(id)
            return id
        }
        let handler: (CFDictionary?) -> Void = { dict in self.handle(id, dict) }
        NStatSourceSetCountsBlock(src, handler)
        NStatSourceSetDescriptionBlock(src, handler)
        NStatSourceSetRemovedBlock(src) { self.removed(id) }
    }

    func handle(_ id: UInt64, _ dict: CFDictionary?) {
        assertOnQueue()
        guard let d = dict as NSDictionary? else { return }
        let (keys, want, budget) = lock.withLock { ($0.keys, $0.wantEndpoints, $0.refineBudget) }
        var sample = NStatParse.sample({ d[$0] }, keys: keys, endpoints: want)
        var refined: NStatKeyMap?
        // A required key absent from the dictionary (not merely zero) → a renamed key: re-discover.
        let missing = d[keys.pid] == nil || d[keys.rx] == nil
        if missing, budget > 0 {
            var k = keys
            if k.refine(with: d.allKeys.compactMap { $0 as? String }) {
                refined = k
                sample = NStatParse.sample({ d[$0] }, keys: k, endpoints: want)
            }
        }
        // Resolve the start time outside the lock, only when the table will ask for it.
        var start: UInt64?
        let upid = sample.uniquePID
        if let pid = sample.pid, lock.withLock({ $0.table.needsStartTime(id, uniquePID: upid) }) {
            start = W6cProcess.startTimeUs(pid: pid, uniquePID: upid)
        }
        let parsed = sample, newKeys = refined, resolved = start
        lock.withLock { s in
            if missing, s.refineBudget > 0 { s.refineBudget -= 1 }
            if let newKeys { s.keys = newKeys }
            s.table.update(id, with: parsed) { _, _ in resolved }
        }
    }

    func removed(_ id: UInt64) {
        assertOnQueue()
        lock.withLock { $0.table.remove(id) }
    }

    /// One query completion block fired; the reading is built when the last one of the current generation has.
    func partCompleted(_ gen: UInt64) {
        assertOnQueue()
        let now = W6cClock.uptimeNs()
        let ready = lock.withLock { s -> (prune: [ProcessID], ifIndexes: [UInt32], names: [UInt32: String])? in
            guard gen == s.generation, s.pendingParts > 0 else { return nil }
            s.pendingParts -= 1
            guard s.pendingParts == 0 else { return nil }
            let prune = now < s.lastPruneNs || now - s.lastPruneNs >= Self.pruneIntervalNs
            let missing = s.wantEndpoints ? s.table.interfaceIndexes().filter { s.interfaceNames[$0] == nil } : []
            return (prune ? s.table.pruneCandidates() : [], missing, s.interfaceNames)
        }
        guard let ready else { return }
        // Syscalls outside the lock.
        let alive = Set(ready.prune.filter(W6cProcess.isAlive))
        var names = ready.names
        for i in ready.ifIndexes { if let n = Self.interfaceName(i) { names[i] = n } }
        let pruneNow = !ready.prune.isEmpty
        let resolvedNames = names
        let signal = lock.withLock { s -> Bool in
            guard gen == s.generation else { return false }
            if pruneNow || now < s.lastPruneNs || now - s.lastPruneNs >= Self.pruneIntervalNs {
                s.table.prune(nowNs: now) { alive.contains($0) }
                s.lastPruneNs = now
            }
            s.interfaceNames = resolvedNames
            s.last = s.table.reading(endpoints: s.wantEndpoints) { resolvedNames[$0] }
            s.lastCapturedNs = now
            if let started = s.queryStartedNs, now >= started { s.lastQueryCostNs = now - started }
            s.queryStartedNs = nil
            defer { s.firstSignalled = true }
            return !s.firstSignalled
        }
        if signal { firstQuery.signal() }
    }

    func reset() {
        assertOnQueue()
        lock.withLock { s in
            let next = s.nextID, gen = s.generation
            s = State()
            s.nextID = next // late callbacks of the old manager carry ids the new table never had
            s.generation = gen
        }
    }

    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }

    private static func interfaceName(_ index: UInt32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        return buf.withUnsafeMutableBufferPointer { b -> String? in
            guard let base = b.baseAddress, if_indextoname(index, base) != nil else { return nil }
            return String(cString: base)
        }
    }
}
