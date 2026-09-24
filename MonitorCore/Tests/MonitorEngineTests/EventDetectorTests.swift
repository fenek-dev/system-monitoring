import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

@Suite struct EventDetectorTests {
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 5_000 + s) }

    private func frame(_ s: Double, cpu: Double? = nil, gpu: Double? = nil, rx: Double? = nil, write: Double? = nil,
                       app: String = "x", swap: UInt64? = nil) -> SystemFrame {
        let a = AppSample(identity: AppIdentity(key: AppKey(kind: .app, id: app), displayName: app), cpuPercent: cpu,
                          gpuPercent: gpu, netRxBps: rx, diskWriteBps: write)
        return SystemFrame(wallTime: at(s), uptimeNs: UInt64(s * 1e9), memory: MemorySnapshot(swapUsed: swap), apps: [a])
    }

    @Test func sleepGapClosesEpisodes() throws {
        var d = EventDetector()
        _ = run(&d, 0, 70) { frame($0, cpu: 300) }
        // system sleeps: uptime moves 5 s, wall clock an hour → the episode ends at its last sample
        var f = frame(75, cpu: 300)
        f.wallTime = at(75 + 3_600)
        let events = d.update(f)
        let closed = try #require(events.first { $0.end != nil })
        #expect(closed.end == at(70))
    }

    @Test func wallClockJumpBackDoesNotBreakDurations() throws {
        var d = EventDetector()
        var events: [HistoryEvent] = []
        for s in stride(from: 0.0, through: 60, by: 5) {
            var f = frame(s, cpu: 300)
            if s >= 30 { f.wallTime = at(s - 7_200) }            // wall clock set back two hours at 30 s
            events += d.update(f)
        }
        #expect(events.count == 1)                                // open event after 60 s of uptime
    }

    /// Feeds one frame per `step` seconds over [from, to]; returns every event.
    private func run(_ d: inout EventDetector, _ from: Double, _ to: Double, step: Double = 5,
                     _ make: (Double) -> SystemFrame) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        for s in stride(from: from, through: to, by: step) { out += d.update(make(s)) }
        return out
    }

    @Test func sustainedCPUEpisodeOpensAtMinDurationAndClosesAfterGap() throws {
        var d = EventDetector()
        var events = run(&d, 0, 55) { frame($0, cpu: 250) }
        #expect(events.isEmpty)                                   // < 60 s so far
        events = run(&d, 60, 90) { frame($0, cpu: $0 == 75 ? 400 : 250) }
        let open = try #require(events.first)
        #expect(events.count == 1)
        #expect(open.kind == .appEpisode && open.metric == .cpu && open.end == nil)
        #expect(open.start == at(0))
        #expect(open.app?.displayName == "x")
        events = run(&d, 95, 125) { frame($0, cpu: 10) }          // below; closes once the gap exceeds 30 s
        let closed = try #require(events.first)
        #expect(events.count == 1)
        #expect(closed.id == open.id)
        #expect(closed.end == at(90))                             // last sample above threshold
        #expect(closed.peak == 400)
    }

    @Test func shortBurstIsNotAnEpisode() {
        var d = EventDetector()
        var events = run(&d, 0, 40) { frame($0, cpu: 300) }
        events += run(&d, 45, 120) { frame($0, cpu: 0) }
        #expect(events.isEmpty)
    }

    @Test func gapsShorterThanMergeGapMerge() throws {
        var d = EventDetector()
        var events = run(&d, 0, 40) { frame($0, cpu: 300) }
        events += run(&d, 45, 60) { frame($0, cpu: 0) }           // 20 s below
        events += run(&d, 65, 100) { frame($0, cpu: 300) }
        events += run(&d, 105, 140) { frame($0, cpu: 0) }
        let closes = events.filter { $0.end != nil }
        #expect(closes.count == 1)
        #expect(closes.first?.start == at(0) && closes.first?.end == at(100))
    }

    @Test func longGapSplitsEpisodes() {
        var d = EventDetector()
        var events = run(&d, 0, 70) { frame($0, cpu: 300) }
        events += run(&d, 75, 120) { frame($0, cpu: 0) }          // 45 s below
        events += run(&d, 125, 200) { frame($0, cpu: 300) }
        events += run(&d, 205, 250) { frame($0, cpu: 0) }
        #expect(Set(events.filter { $0.end != nil }.map(\.id)).count == 2)
    }

    @Test func missingAppCountsAsBelow() {
        var d = EventDetector()
        var events = run(&d, 0, 70) { frame($0, cpu: 300) }
        events += run(&d, 75, 110) { frame($0, cpu: 300, app: "other-app-only") }   // "x" gone
        #expect(events.contains { $0.end != nil && $0.app?.displayName == "x" })
    }

    @Test(arguments: [AppMetric.gpu, .netRx, .diskWrite])
    func otherMetricThresholds(_ metric: AppMetric) {
        var d = EventDetector()
        let events = run(&d, 0, 60) { s in
            switch metric {
            case .gpu: frame(s, gpu: 30)
            case .netRx: frame(s, rx: 10e6)
            default: frame(s, write: 50e6)
            }
        }
        #expect(events.map(\.metric) == [metric])
        var below = EventDetector()
        let none = run(&below, 0, 60) { s in
            switch metric {
            case .gpu: frame(s, gpu: 29)
            case .netRx: frame(s, rx: 9.9e6)
            default: frame(s, write: 49e6)
            }
        }
        #expect(none.isEmpty)
    }

    @Test func flushClosesQualifyingEpisodesOnly() {
        var d = EventDetector()
        let opened = run(&d, 0, 70) { frame($0, cpu: 300) }      // 70 s: qualifies (open event at 60 s)
        let flushed = d.flush(at: at(75))
        #expect(flushed.count == 1)
        #expect(flushed.first?.id == opened.first?.id)
        #expect(flushed.first?.end == at(70))
        #expect(d.flush(at: at(80)).isEmpty)
        var short = EventDetector()
        _ = run(&short, 0, 20) { frame($0, cpu: 300) }
        #expect(short.flush(at: at(30)).isEmpty)
    }

    @Test func swapGrowthEvent() throws {
        var d = EventDetector()
        var events = run(&d, 0, 60) { frame($0, swap: 1 << 30) }
        events += run(&d, 65, 300, step: 5) { s in frame(s, swap: UInt64(1 << 30) + UInt64((s - 60) / 240 * Double(1 << 30))) }
        let e = try #require(events.first { $0.kind == .swapGrowth })
        #expect(e.level == .elevated)
        #expect(e.peak != nil)
        #expect(events.filter { $0.kind == .swapGrowth }.count == 1)   // once until swap shrinks again
    }
}
