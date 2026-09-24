import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import Testing

/// Records share queries and exports; `appShares` can be held until `release()` (in-flight cancellation).
actor FakeHistoryProvider: HistoryProvider {
    private(set) var shareTimes: [Date] = []
    private(set) var shareRanges: [HistoryRange] = []
    private(set) var exports: [(HistoryRange, Date, URL)] = []
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() { holding = true }
    func release() {
        holding = false
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] {
        [:]
    }
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] { [:] }
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] {
        shareTimes.append(time)
        shareRanges.append(range)
        if holding { await withCheckedContinuation { waiters.append($0) } }
        return [AppShare(identity: AppIdentity(key: AppKey(kind: .app, id: "a.\(range.rawValue)"), displayName: "A"),
                         value: time.timeIntervalSince1970.truncatingRemainder(dividingBy: 1000) + 1, fraction: 1)]
    }
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { [] }
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    func events(in interval: DateInterval) async throws -> [HistoryEvent] { [] }
    func coverage() async throws -> DateInterval? { nil }
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        exports.append((range, end, url))
        return ExportSummary(rows: 288, bytes: 1000, url: url)
    }
}

enum HT {
    static let now = MockDataProvider.referenceDate
    static var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    @MainActor static func model(_ range: HistoryRange = .day, provider: any HistoryProvider = FakeHistoryProvider())
        -> HistoryModel {
        let m = HistoryModel(range: range, now: now, provider: provider, calendar: london)
        m.select(range, now: now)
        return m
    }

    static func share(_ name: String, _ value: Double) -> AppShare {
        AppShare(identity: AppIdentity(key: AppKey(kind: .app, id: name), displayName: name), value: value, fraction: 0)
    }
}

@Suite("History — windows & copy")
struct HistoryWindowTests {
    @Test func calendarAlignedWindows() {
        let cal = HT.london
        let day = HistoryWindow.make(.day, now: HT.now, calendar: cal)
        #expect(day.start == cal.startOfDay(for: HT.now))
        #expect(day.count == 288)
        let minutes = cal.dateComponents([.hour, .minute], from: HT.now)
        #expect(day.latest == (minutes.hour! * 60 + minutes.minute!) / 5)
        #expect(day.end == cal.date(byAdding: .day, value: 1, to: day.start))
        let week = HistoryWindow.make(.week, now: HT.now, calendar: cal)
        #expect(week.count == 336 && week.start == cal.date(byAdding: .day, value: -6, to: day.start))
        let month = HistoryWindow.make(.month, now: HT.now, calendar: cal)
        #expect(month.count == 360 && month.start == cal.date(byAdding: .day, value: -29, to: day.start))
        let hour = HistoryWindow.make(.hour, now: HT.now, calendar: cal)
        #expect(hour.count == 240 && hour.latest == 239 && hour.end >= HT.now)
        let live = HistoryWindow.make(.live, now: HT.now, calendar: cal)
        #expect(live.count == 60 && live.latest == 59)
        #expect(day.index(of: day.time(at: 100).addingTimeInterval(299)) == 100)
    }

    @Test func bucketedPlacesPointsByTime() {
        let w = HistoryWindow(range: .hour, start: HT.now, bucket: 15, count: 4, latest: 3)
        let pts = [SeriesPoint(time: HT.now.addingTimeInterval(30), value: 2),
                   SeriesPoint(time: HT.now.addingTimeInterval(-15), value: 9),     // outside
                   SeriesPoint(time: HT.now, value: .nan)]
        #expect(HistoryModel.bucketed(pts, window: w) == [nil, nil, 2, nil])
    }

    @Test func copy() {
        #expect(HistoryText.subtitle(.day) == "Stored locally · 5-minute resolution for 24 h · kept for 30 days")
        #expect(HistoryText.subtitle(.live) == "Stored locally · 1-second resolution for 60 s · kept for 30 days")
        let tz = TimeZone(identifier: "Europe/London")!
        let gb = Locale(identifier: "en_GB")
        let day = HistoryWindow.make(.day, now: HT.now, calendar: HT.london)
        #expect(HistoryText.title(day, now: HT.now, locale: gb, timeZone: tz) == "Thursday 24 September")
        let week = HistoryWindow.make(.week, now: HT.now, calendar: HT.london)
        #expect(HistoryText.title(week, now: HT.now, locale: gb, timeZone: tz) == "18 – 24 September")
        let month = HistoryWindow.make(.month, now: HT.now, calendar: HT.london)
        #expect(HistoryText.title(month, now: HT.now, locale: gb, timeZone: tz) == "26 August – 24 September")
        let us = Locale(identifier: "en_US")
        #expect(HistoryText.title(week, now: HT.now, locale: us, timeZone: tz) == "September 18 – 24")
        #expect(HistoryText.title(month, now: HT.now, locale: us, timeZone: tz) == "August 26 – September 24")
        let live = HistoryWindow.make(.live, now: HT.now, calendar: HT.london)
        #expect(HistoryText.title(live, now: HT.now, locale: gb, timeZone: tz) == "Last 60 seconds")
        #expect(HistoryText.laneValue(.cpuUsage, 0.8, units: UnitPreferences()) == "80%")
        #expect(HistoryText.laneValue(.netRx, 6_000_000, units: UnitPreferences()) == "6.0 MB/s")
        #expect(HistoryText.laneValue(.socTemp, 76, units: UnitPreferences()) == "76°C")
        #expect(HistoryText.laneValue(.packageWatts, 42.2, units: UnitPreferences()) == "42.2 W")
        #expect(HistoryText.topProcess(HT.share("Xcode", 812), metric: .cpu, units: UnitPreferences())
            == "Xcode · 812% CPU")
    }

    @Test func notesFromOverlappingEvents() {
        let e = HistoryEvent(kind: .runawayApp, start: HT.now, end: HT.now.addingTimeInterval(600), level: .elevated,
                             app: AppIdentity(key: HT.share("Xcode", 1).id, displayName: "Xcode"), label: "")
        let t = HistoryEvent(kind: .thermalPressure, start: HT.now, end: nil, level: .elevated, peak: 1, label: "")
        #expect(HistoryText.note([e, t], at: HT.now.addingTimeInterval(60), bucket: 300, now: HT.now.addingTimeInterval(900))
            == "CPU spike from Xcode. Thermal pressure went to Fair.")
        #expect(HistoryText.note([e], at: HT.now.addingTimeInterval(3_600), bucket: 300, now: HT.now)
            == "Nothing unusual in this window.")
        #expect(HistoryText.chipLabel(HistoryEvent(start: HT.now, label: "Xcode build"),
                                      timeZone: TimeZone(identifier: "Europe/London")!).hasPrefix("Xcode build · "))
    }

    @Test func overlappingChipsCollapseBehindPlusN() {
        let w = HistoryWindow.make(.day, now: HT.now, calendar: HT.london)
        let a = HistoryEvent(start: w.time(at: 100), level: .calm, label: "A")
        let b = HistoryEvent(start: w.time(at: 101), level: .critical, label: "B")
        let c = HistoryEvent(start: w.time(at: 250), level: .calm, label: "C")
        let chips = HistoryChip.layout([a, b, c], window: w, width: 810, label: { $0.label }, measure: { _ in 60 })
        #expect(chips.map(\.text) == ["B", "C"])                          // severity wins the overlap
        #expect(chips.first?.hidden == 1)
        #expect(chips.allSatisfy { $0.x - $0.width / 2 >= 0 && $0.x + $0.width / 2 <= 810 })
    }

    @Test func bandsAndLegendKinds() {
        let w = HistoryWindow.make(.day, now: HT.now, calendar: HT.london)
        let fair = HistoryEvent(kind: .thermalPressure, start: w.time(at: 10), end: w.time(at: 20), level: .elevated,
                                peak: Double(ThermalPressure.fair.rawValue))
        let paused = HistoryEvent(kind: .samplingPaused, start: w.time(at: 50), end: w.time(at: 62), level: .calm)
        let bands = HistoryBand.layout([fair, paused, HistoryEvent(kind: .appEpisode, start: w.time(at: 1))],
                                       window: w, width: 287, now: HT.now)
        #expect(bands.map(\.kind) == [.fair, .paused])
        #expect(bands[0].x0 == 10 && bands[0].x1 == 20)
    }

    @Test func treemapSharesFoldSmallAppsIntoOtherLast() {
        let raw = [HT.share("a", 50), HT.share("b", 45), HT.share("c", 1), HT.share("d", 1),
                   AppShare(identity: AppIdentity(key: .other, displayName: "Other"), value: 3, fraction: 0)]
        let r = HistoryModel.treemapShares(raw)
        #expect(r.shares.map(\.identity.displayName) == ["a", "b", "Other"])
        #expect(r.shares.last?.value == 5)
        #expect(r.otherCount == 3)
        #expect(abs((r.shares.first?.fraction ?? 0) - 0.5) < 1e-9)
        #expect(HistoryModel.treemapShares([]).shares.isEmpty)
        let summed = HistoryModel.sumByApp([[HT.share("a", 1)], [HT.share("a", 2), HT.share("b", 1)]])
        #expect(summed.map(\.value) == [3, 1])
    }

    @Test func throttleFiresAtMostTenPerSecond() {
        var t = ShareQueryThrottle(interval: 0.1)
        var fires = 0
        var scheduled: Double?
        var now = 0.0
        while now < 1.0 {
            if let s = scheduled, now >= s {
                t.firedScheduled(at: now)
                scheduled = nil
                fires += 1
            }
            switch t.request(at: now) {
            case .fireNow: fires += 1
            case .schedule(let at): scheduled = at
            case .coalesce: break
            }
            now += 0.005                                                // 200 scrub events/s
        }
        #expect(fires <= 11)
        #expect(fires >= 9)
    }
}

@Suite("HistoryModel — cursor, pin, queries, export")
@MainActor
struct HistoryModelTests {
    @Test func storedRangesStartAtLatestUnpinned() {
        let m = HT.model(.day)
        #expect(!m.pinned)
        #expect(m.cursor == m.window.latest)
        #expect(m.isAtLatest)
        m.step(-1)
        #expect(m.cursor == m.window.latest - 1 && !m.pinned)
    }

    @Test func livePinsFollowsUnpinsAndRepins() {
        let m = HT.model(.live)
        #expect(m.pinned)
        let apps = [AppSample(identity: AppIdentity(key: HT.share("x", 1).id, displayName: "X"), cpuPercent: 80)]
        m.applyLive(series: [:], now: HT.now.addingTimeInterval(1), apps: apps)
        #expect(m.cursor == 59 && m.pinned)
        #expect(m.topShare?.identity.displayName == "X")
        #expect(m.sharesTime == nil)                                       // live apps, not a store query
        m.scrub(to: 40)
        #expect(!m.pinned)
        let t = m.cursorTime
        m.applyLive(series: [:], now: HT.now.addingTimeInterval(2), apps: apps)
        #expect(m.cursorTime == t && m.cursor == 39)                      // keeps its moment as the window moves
        m.endScrub()
        m.scrub(to: 59)
        #expect(m.pinned)                                                  // back on the newest bucket
        m.scrub(to: 10)
        m.repin()
        #expect(m.pinned && m.cursor == 59)
    }

    @Test func scrubQueriesAreThrottledAndEndOnTheFinalCursor() async throws {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        let start = ContinuousClock.now
        for i in 0..<50 {
            m.scrub(to: 100 + i)
            try await Task.sleep(for: .milliseconds(10))
        }
        m.endScrub()
        let elapsed = ContinuousClock.now - start
        let final = m.window.time(at: 149)
        await waitUntil { m.sharesTime == final }
        let times = await provider.shareTimes
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        #expect(Double(times.count) <= seconds * 10 + 2)                   // ≤ 10/s (+ leading and trailing)
        #expect(times.count < 50)
        #expect(times.last == final)                                        // trailing query = final position
        #expect(m.sharesTime == final)
    }

    @Test func rangeChangeCancelsInFlightQuery() async throws {
        let provider = FakeHistoryProvider()
        await provider.hold()
        let m = HT.model(.day, provider: provider)
        m.scrub(to: 50)
        await waitUntil { await provider.shareTimes.count == 1 }            // in flight, held
        #expect(await provider.shareTimes.count == 1)
        m.select(.week, now: HT.now)
        await provider.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.shares.isEmpty)                                          // the old 24H result was dropped
        #expect(m.range == .week && m.cursor == m.window.latest)
    }

    @Test func metricChangeRequeries() async throws {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        m.metric = .network
        await waitUntil { await provider.shareTimes.count == 2 }
        #expect(await provider.shareTimes.count == 2)                      // ↓ and ↑ summed
    }

    /// Polls (10 ms) until `condition` holds or 3 s pass — robust under a loaded test runner.
    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func exportAsksForDestinationThenExportsTheRange() async {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        let none = await m.export { nil }
        #expect(none == nil)
        #expect(await provider.exports.isEmpty)
        let url = URL(fileURLWithPath: "/tmp/telltale-test.csv")
        let summary = await m.export { url }
        #expect(summary?.rows == 288)
        let calls = await provider.exports
        #expect(calls.count == 1)
        #expect(calls.first?.0 == .day && calls.first?.1 == m.window.end && calls.first?.2 == url)
        #expect(m.exportStatus == "Exported 288 rows")
    }

    @Test func loadsMockHistoryIntoLanes() async {
        let provider = MockDataProvider(scenario: .calm).history()
        let m = HT.model(.day, provider: provider)
        await m.load()
        #expect(m.loadState == .loaded)
        let cpu = m.lanes[.cpuUsage] ?? []
        #expect(cpu.count == 288)
        #expect(cpu[m.window.latest - 1] != nil)
        #expect(cpu[m.window.latest + 12] == nil)                          // the future is a gap
        #expect(!m.events.isEmpty)
        #expect(!m.shares.isEmpty)
    }

    @Test func loadSynchronouslyForSnapshots() {
        let provider = MockDataProvider(scenario: .calm).history()
        let m = HT.model(.day, provider: provider)
        m.loadSynchronously()
        #expect(m.loadState == .loaded)
        #expect(!m.shares.isEmpty)
    }
}
