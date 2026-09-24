import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct NStatFlowTableTests {
    static let minute: UInt64 = 60_000_000_000

    static func s(pid: Int32? = 100, upid: UInt64? = 1, rx: UInt64?, tx: UInt64?, proto: TransportProtocol = .tcp,
                  epid: Int32? = nil, endpoints: NStatEndpoints? = nil) -> NStatSourceSample {
        NStatSourceSample(pid: pid, uniquePID: upid, effectivePID: epid, processName: "p", proto: proto,
                          rxBytes: rx, txBytes: tx, endpoints: endpoints)
    }

    /// pid → start time; mutable so tests can simulate pid reuse.
    final class Starts {
        var map: [Int32: UInt64] = [100: 5_000]
        var calls = 0
        func lookup(_ pid: Int32, _ uniquePID: UInt64?) -> UInt64? {
            calls += 1
            return map[pid]
        }
    }

    @Test func liveFlowsCarryCumulativeCountsAndResolvedProcess() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(rx: 10, tx: 1), startTime: st.lookup)
        t.update(1, with: Self.s(rx: 30, tx: 5), startTime: st.lookup)
        let r = t.reading(endpoints: false) { _ in nil }
        #expect(r.flows.count == 1)
        #expect(r.flows[0].flowID == 1)
        #expect(r.flows[0].process == ProcessID(pid: 100, startTimeUs: 5_000))
        #expect(r.flows[0].rxBytes == 30 && r.flows[0].txBytes == 5)
        #expect(st.calls == 1) // resolved once per source
    }

    @Test func counterNeverRegresses() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(rx: 50, tx: 50), startTime: st.lookup)
        t.update(1, with: Self.s(rx: 20, tx: nil), startTime: st.lookup)
        let f = t.reading(endpoints: false) { _ in nil }.flows[0]
        #expect(f.rxBytes == 50 && f.txBytes == 50)
    }

    @Test func removalFoldsFinalBytesIntoClosed() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.add(2)
        t.update(1, with: Self.s(rx: 100, tx: 10), startTime: st.lookup)
        t.update(2, with: Self.s(rx: 7, tx: 3), startTime: st.lookup)
        let before = t.reading(endpoints: false) { _ in nil }
        t.remove(1)
        let after = t.reading(endpoints: false) { _ in nil }
        let pidKey = ProcessID(pid: 100, startTimeUs: 5_000)
        #expect(after.flows.map(\.flowID) == [2])
        #expect(after.closedBytes[pidKey] == ByteCounts(rx: 100, tx: 10))
        // Per-process total (live + closed) is monotonic across the removal.
        func total(_ r: NetworkFlowsReading) -> UInt64 {
            r.flows.filter { $0.process == pidKey }.reduce(0) { $0 + $1.rxBytes } + (r.closedBytes[pidKey]?.rx ?? 0)
        }
        #expect(total(after) >= total(before))
        // Second removal of the same id is a no-op; late counts for a removed id are ignored.
        t.remove(1)
        t.update(1, with: Self.s(rx: 999, tx: 999), startTime: st.lookup)
        #expect(t.reading(endpoints: false) { _ in nil }.closedBytes[pidKey] == ByteCounts(rx: 100, tx: 10))
        #expect(t.reading(endpoints: false) { _ in nil }.flows.count == 1)
    }

    @Test func closedAccumulatesAcrossFlows() {
        var t = NStatFlowTable()
        let st = Starts()
        for id in UInt64(1)...5 {
            t.add(id)
            t.update(id, with: Self.s(rx: 10, tx: 2), startTime: st.lookup)
            t.remove(id)
        }
        #expect(t.reading(endpoints: false) { _ in nil }.closedBytes[ProcessID(pid: 100, startTimeUs: 5_000)] == ByteCounts(rx: 50, tx: 10))
        #expect(st.calls == 1) // start time cached per uniqueProcessID
    }

    @Test func closedSaturatesInsteadOfWrapping() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(rx: .max, tx: 1), startTime: st.lookup)
        t.remove(1)
        t.add(2)
        t.update(2, with: Self.s(rx: 10, tx: 1), startTime: st.lookup)
        t.remove(2)
        #expect(t.reading(endpoints: false) { _ in nil }.closedBytes[ProcessID(pid: 100, startTimeUs: 5_000)]?.rx == .max)
    }

    @Test func pidReuseGetsANewProcessID() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(upid: 1, rx: 40, tx: 4), startTime: st.lookup)
        t.remove(1)
        st.map[100] = 9_000 // pid 100 exited and was reused
        t.add(2)
        t.update(2, with: Self.s(upid: 2, rx: 3, tx: 1), startTime: st.lookup)
        let r = t.reading(endpoints: false) { _ in nil }
        #expect(r.closedBytes[ProcessID(pid: 100, startTimeUs: 5_000)] == ByteCounts(rx: 40, tx: 4))
        #expect(r.flows[0].process == ProcessID(pid: 100, startTimeUs: 9_000))
    }

    @Test func unknownStartTimeIsPidZero() {
        var t = NStatFlowTable()
        t.add(1)
        t.update(1, with: Self.s(pid: 777, upid: 55, rx: 5, tx: 5)) { _, _ in nil }
        t.remove(1)
        #expect(t.reading(endpoints: false) { _ in nil }.closedBytes[ProcessID(pid: 777, startTimeUs: 0)] == ByteCounts(rx: 5, tx: 5))
    }

    @Test func sourcesRetiredBeforePidResolvesAreUnattributed() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(pid: nil, upid: nil, rx: 8, tx: 2), startTime: st.lookup)
        #expect(t.reading(endpoints: false) { _ in nil }.flows.isEmpty) // no process yet → not a flow
        #expect(t.unresolvedCount == 1)
        t.remove(1)
        t.add(2)
        t.remove(2) // never saw any callback
        let r = t.reading(endpoints: false) { _ in nil }
        #expect(r.unattributedBytes == ByteCounts(rx: 8, tx: 2))
        #expect(r.closedBytes.isEmpty)
    }

    /// Counts arrive before the description: bytes are kept and the flow appears once the pid resolves.
    @Test func countsBeforeDescriptionResolveLater() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(pid: nil, upid: nil, rx: 500, tx: 5), startTime: st.lookup)
        #expect(t.unresolvedCount == 1)
        t.update(1, with: Self.s(rx: 600, tx: 6), startTime: st.lookup)
        #expect(t.unresolvedCount == 0)
        let f = t.reading(endpoints: false) { _ in nil }.flows
        #expect(f.count == 1 && f[0].rxBytes == 600 && f[0].process.pid == 100)
    }

    @Test func helperQueriesForTheBox() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        #expect(t.needsStartTime(1, uniquePID: 1))
        #expect(!t.needsStartTime(9, uniquePID: 1)) // unknown source
        t.update(1, with: Self.s(rx: 1, tx: 1, endpoints: NStatEndpoints(interfaceIndex: 11)), startTime: st.lookup)
        #expect(!t.needsStartTime(1, uniquePID: 1)) // resolved
        t.add(2)
        #expect(!t.needsStartTime(2, uniquePID: 1)) // uniqueProcessID cached
        #expect(t.needsStartTime(2, uniquePID: nil))
        #expect(t.interfaceIndexes() == [11])
        t.remove(1)
        #expect(t.pruneCandidates() == [ProcessID(pid: 100, startTimeUs: 5_000)])
        t.update(2, with: Self.s(rx: 1, tx: 1), startTime: st.lookup)
        #expect(t.pruneCandidates().isEmpty) // process has a live flow again
    }

    @Test func effectivePIDOnlyWhenDelegated() {
        var t = NStatFlowTable()
        let st = Starts()
        st.map[200] = 1
        t.add(1)
        t.update(1, with: Self.s(rx: 1, tx: 1, epid: 100), startTime: st.lookup)
        t.add(2)
        t.update(2, with: Self.s(pid: 200, upid: 9, rx: 1, tx: 1, epid: 100), startTime: st.lookup)
        let flows = t.reading(endpoints: false) { _ in nil }.flows
        #expect(flows.first { $0.flowID == 1 }?.effectivePID == nil)
        #expect(flows.first { $0.flowID == 2 }?.effectivePID == 100)
    }

    @Test func endpointsOnlyWhenRequested() {
        var t = NStatFlowTable()
        let st = Starts()
        let e = NStatEndpoints(localPort: 5000, remoteAddress: "1.2.3.4", remotePort: 443, tcpState: "Established", interfaceIndex: 11)
        t.add(1)
        t.update(1, with: Self.s(rx: 1, tx: 1, endpoints: e), startTime: st.lookup)
        let off = t.reading(endpoints: false) { _ in "en0" }.flows[0]
        #expect(off.remoteAddress == nil && off.localPort == nil && off.tcpState == nil && off.interface == nil)
        let on = t.reading(endpoints: true) { $0 == 11 ? "en0" : nil }.flows[0]
        #expect(on.localPort == 5000 && on.remoteAddress == "1.2.3.4" && on.remotePort == 443)
        #expect(on.tcpState == "Established" && on.interface == "en0")
        // A later update without endpoints (connections demand dropped) keeps the table lean.
        t.update(1, with: Self.s(rx: 2, tx: 2), startTime: st.lookup)
        #expect(t.reading(endpoints: true) { _ in "en0" }.flows[0].remoteAddress == nil)
    }

    @Test func prunesClosedEntriesTenMinutesAfterExit() {
        var t = NStatFlowTable()
        let st = Starts()
        st.map[300] = 3
        t.add(1)
        t.update(1, with: Self.s(rx: 10, tx: 1), startTime: st.lookup)
        t.remove(1)
        t.add(2)
        t.update(2, with: Self.s(pid: 300, upid: 3, rx: 1, tx: 1), startTime: st.lookup)
        t.remove(2)
        let dead = ProcessID(pid: 100, startTimeUs: 5_000)
        let alive = ProcessID(pid: 300, startTimeUs: 3)
        let isAlive: (ProcessID) -> Bool = { $0 == alive }
        t.prune(nowNs: 1 * Self.minute, isAlive: isAlive) // first seen dead at 1 min
        t.prune(nowNs: 10 * Self.minute, isAlive: isAlive) // 9 min dead → kept
        #expect(t.reading(endpoints: false) { _ in nil }.closedBytes[dead] != nil)
        t.prune(nowNs: 11 * Self.minute, isAlive: isAlive) // 10 min dead → pruned
        let r = t.reading(endpoints: false) { _ in nil }
        #expect(r.closedBytes[dead] == nil)
        #expect(r.closedBytes[alive] == ByteCounts(rx: 1, tx: 1))
        #expect(t.deadSinceCount == 0)
    }

    /// `(pid, 0)` entries: liveness by pid would match a reused pid forever, so they expire 10 min after their last
    /// fold regardless of `isAlive`; a new fold restarts the clock.
    @Test func loosePidZeroEntriesExpire() {
        var t = NStatFlowTable()
        func fold(_ id: UInt64, pid: Int32 = 777) {
            t.add(id)
            t.update(id, with: Self.s(pid: pid, upid: nil, rx: 5, tx: 5)) { _, _ in nil }
            t.remove(id)
        }
        fold(1)
        let loose = ProcessID(pid: 777, startTimeUs: 0)
        let sentinel = ProcessID(pid: 778, startTimeUs: W6cProcess.exitedStartTimeUs)
        t.add(2)
        t.update(2, with: Self.s(pid: 778, upid: 9, rx: 1, tx: 1)) { _, _ in W6cProcess.exitedStartTimeUs }
        t.remove(2)
        #expect(t.pruneCandidates().isEmpty) // no liveness syscalls for loose keys
        t.prune(nowNs: 0) { _ in true } // "alive" by pid: ignored
        t.prune(nowNs: 9 * Self.minute) { _ in true }
        fold(3) // new bytes at 9 min → clock restarts for (777, 0)
        t.prune(nowNs: 10 * Self.minute) { _ in true }
        var r = t.reading(endpoints: false) { _ in nil }
        #expect(r.closedBytes[loose] == ByteCounts(rx: 10, tx: 10))
        #expect(r.closedBytes[sentinel] == nil) // 10 min since first seen
        t.prune(nowNs: 20 * Self.minute) { _ in true }
        r = t.reading(endpoints: false) { _ in nil }
        #expect(r.closedBytes.isEmpty)
    }

    @Test func processWithLiveFlowIsNeverPrunedAndRevivalResetsClock() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(rx: 10, tx: 1), startTime: st.lookup)
        t.remove(1)
        t.add(2)
        t.update(2, with: Self.s(rx: 1, tx: 1), startTime: st.lookup) // still has a live flow
        t.prune(nowNs: 0, isAlive: { _ in false })
        t.prune(nowNs: 30 * Self.minute, isAlive: { _ in false })
        #expect(t.reading(endpoints: false) { _ in nil }.closedBytes.count == 1)
    }

    @Test func startTimeCacheIsBoundedByLiveSources() {
        var t = NStatFlowTable()
        let st = Starts()
        for id in UInt64(1)...50 {
            st.map[Int32(1_000 + id)] = id
            t.add(id)
            t.update(id, with: Self.s(pid: Int32(1_000 + id), upid: 10_000 + id, rx: 1, tx: 1), startTime: st.lookup)
            t.remove(id)
        }
        #expect(t.startTimeCacheCount == 50)
        t.prune(nowNs: 0, isAlive: { _ in true })
        #expect(t.startTimeCacheCount == 0)
        #expect(t.sourceCount == 0)
    }

    @Test func resetClearsEverything() {
        var t = NStatFlowTable()
        let st = Starts()
        t.add(1)
        t.update(1, with: Self.s(rx: 1, tx: 1), startTime: st.lookup)
        t.remove(1)
        t = NStatFlowTable()
        let r = t.reading(endpoints: false) { _ in nil }
        #expect(r.flows.isEmpty && r.closedBytes.isEmpty && r.unattributedBytes == ByteCounts())
    }
}
