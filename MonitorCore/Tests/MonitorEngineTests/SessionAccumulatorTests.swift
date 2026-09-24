import MonitorModel
import Testing
@testable import MonitorEngine

@Suite struct SessionAccumulatorTests {
    let a = AppKey(kind: .app, id: "a"), b = AppKey(kind: .app, id: "b")
    let p1 = ProcessID(pid: 1, startTimeUs: 1), p2 = ProcessID(pid: 2, startTimeUs: 1)

    private func app(_ key: AppKey, _ ids: [ProcessID]) -> AppSample {
        AppSample(identity: AppIdentity(key: key, displayName: key.id), processIDs: ids)
    }

    @Test func accumulatesPerAppAcrossTicks() {
        var s = SessionAccumulator()
        s.add([app(a, [p1, p2])], processDeltas: [p1: (10, 1, 100, 5), p2: (5, 0, 0, 1)])
        s.add([app(a, [p1, p2])], processDeltas: [p1: (10, 2, 50, 0)])
        let t = s.totals(a)
        #expect(t.cpuNs == 25 && t.gpuNs == 3 && t.rx == 150 && t.tx == 6)
    }

    @Test func survivesProcessAndAppExit() {
        var s = SessionAccumulator()
        s.add([app(a, [p1])], processDeltas: [p1: (10, 0, 0, 0)])
        s.add([], processDeltas: [:])                          // app gone
        #expect(s.totals(a).cpuNs == 10)
    }

    @Test func appKeyChangeStartsNewTotalsAndKeepsOld() {
        var s = SessionAccumulator()
        s.add([app(a, [p1])], processDeltas: [p1: (10, 0, 0, 0)])
        s.add([app(b, [p1])], processDeltas: [p1: (7, 0, 0, 0)])  // same process now grouped under b
        #expect(s.totals(a).cpuNs == 10)
        #expect(s.totals(b).cpuNs == 7)
    }

    @Test func unknownKeyIsZeroAndUnmappedDeltasIgnored() {
        var s = SessionAccumulator()
        s.add([app(a, [p1])], processDeltas: [p2: (99, 0, 0, 0)])
        #expect(s.totals(a).cpuNs == 0)
        #expect(s.totals(b) == (0, 0, 0, 0))
    }

    @Test func byAppDeltasIncludeSyntheticAndUnattributed() {
        var s = SessionAccumulator()
        s.add(byApp: [.system: ProcessDelta(cpuNs: 3, gpuNs: 4, rx: 5, tx: 6)])
        s.add(byApp: [.system: ProcessDelta(cpuNs: 1)])
        #expect(s.totals(.system) == (4, 4, 5, 6))
    }

    @Test func keysUnseenForADayArePruned() {
        let hour: UInt64 = 3_600 * sec, t0: UInt64 = 100 * hour
        var s = SessionAccumulator()
        s.add(byApp: [a: ProcessDelta(cpuNs: 1), b: ProcessDelta(cpuNs: 2)], atUptimeNs: t0)
        s.pruneUnseen(atUptimeNs: t0)                                    // arms the hourly check
        // a keeps a row (no deltas) all day; b has neither
        for h in stride(from: 1, through: 24, by: 1) {
            _ = s.totalsMarkingSeen(a, atUptimeNs: t0 + UInt64(h) * hour)
            s.pruneUnseen(atUptimeNs: t0 + UInt64(h) * hour)
        }
        #expect(s.keyCount == 2)                                         // exactly 24 h: kept
        _ = s.totalsMarkingSeen(a, atUptimeNs: t0 + 25 * hour)
        s.pruneUnseen(atUptimeNs: t0 + 25 * hour)
        #expect(s.keyCount == 1)
        #expect(s.totals(a).cpuNs == 1)
        #expect(s.totals(b) == (0, 0, 0, 0))
        // marking a key without totals creates nothing
        #expect(s.totalsMarkingSeen(b, atUptimeNs: t0 + 26 * hour).disk == nil)
        #expect(s.keyCount == 1)
    }

    @Test func pruneIsHourlyNotPerTick() {
        let hour: UInt64 = 3_600 * sec, t0: UInt64 = 100 * hour
        var s = SessionAccumulator()
        s.add(byApp: [b: ProcessDelta(cpuNs: 2)], atUptimeNs: t0)
        s.pruneUnseen(atUptimeNs: t0 + 24 * hour + 1)                    // first call only arms
        #expect(s.keyCount == 1)
        s.pruneUnseen(atUptimeNs: t0 + 24 * hour + 2)                    // not due yet
        #expect(s.keyCount == 1)
        s.pruneUnseen(atUptimeNs: t0 + 25 * hour + 1)
        #expect(s.keyCount == 0)
    }

    @Test func saturatesInsteadOfTrapping() {
        var s = SessionAccumulator()
        s.add(byApp: [a: ProcessDelta(cpuNs: .max)])
        s.add(byApp: [a: ProcessDelta(cpuNs: 5)])
        #expect(s.totals(a).cpuNs == .max)
    }
}
