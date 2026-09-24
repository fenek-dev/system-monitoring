import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import os
import Testing

/// Records share queries and exports; `appShares` can be held until `release()` (in-flight cancellation).
actor FakeHistoryProvider: HistoryProvider {
    struct ExportFailure: LocalizedError { var errorDescription: String? { "Disk full" } }

    private(set) var shareTimes: [Date] = []
    private(set) var shareRanges: [HistoryRange] = []
    private(set) var exports: [(HistoryRange, Date, URL)] = []
    private var holding = false
    private var failExport = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() { holding = true }
    func failExports() { failExport = true }
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
        if failExport { throw ExportFailure() }
        return ExportSummary(rows: 288, bytes: 1000, url: url)
    }
}

/// CPU values from bucket `from` on (window buckets), `coverage()` nil.
struct SeriesOnlyProvider: HistoryProvider {
    let from: Int
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] {
        let b = Double(range.displayBucket.components.seconds)
        let n = Int(Double(range.duration!.components.seconds) / b)
        let start = end.addingTimeInterval(-Double(n) * b)
        return [.cpuUsage: (0..<n).map { SeriesPoint(time: start.addingTimeInterval(Double($0) * b), value: $0 >= from ? 0.2 : nil) }]
    }
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] { [:] }
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] { [] }
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { [] }
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    func events(in interval: DateInterval) async throws -> [HistoryEvent] { [] }
    func coverage() async throws -> DateInterval? { nil }
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary { ExportSummary(rows: 0, bytes: 0, url: url) }
}

/// Export destination stub (nil = the user cancelled).
struct StubDestination: HistoryExportDestination {
    let url: URL?
    func chooseDestination(suggestedName: String) async -> URL? { url }
}

/// Manual monotonic clock for the throttle; `sleepUntil` waits for the test to advance it.
final class ManualClock: Sendable {
    private let t = OSAllocatedUnfairLock(initialState: 1_000.0)
    var now: Double { t.withLock { $0 } }
    func advance(_ s: Double) { t.withLock { $0 += s } }
    var read: @Sendable () -> Double { { [self] in now } }
    var sleepUntil: @Sendable (Double) async -> Void {
        { [self] target in
            while now < target {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}

enum HT {
    static let now = MockDataProvider.referenceDate
    /// The snapshot calendar: Europe/London, en_US.
    static var london: Calendar { london("en_US") }

    static func london(_ locale: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: locale)
        return c
    }

    @MainActor static func model(_ range: HistoryRange = .day, provider: any HistoryProvider = FakeHistoryProvider(),
                                 clock: ManualClock? = nil) -> HistoryModel {
        let m = clock.map {
            HistoryModel(range: range, now: now, provider: provider, calendar: london, clock: $0.read,
                         sleepUntil: $0.sleepUntil)
        } ?? HistoryModel(range: range, now: now, provider: provider, calendar: london)
        m.select(range, now: now)
        return m
    }

    static func share(_ name: String, _ value: Double) -> AppShare {
        AppShare(identity: AppIdentity(key: AppKey(kind: .app, id: name), displayName: name), value: value, fraction: 0)
    }
}

/// Polls until `condition` holds, for up to 2,000 main-actor turns (~10 s idle). Counted in turns, not wall time:
/// other suites rendering snapshots on the main actor can stall it for seconds without eating the budget.
@MainActor func waitUntil(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
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
        #expect(day.dataEnd == day.time(at: day.latest).addingTimeInterval(300))
        let week = HistoryWindow.make(.week, now: HT.now, calendar: cal)
        #expect(week.count == 336 && week.start == cal.date(byAdding: .day, value: -6, to: day.start))
        let month = HistoryWindow.make(.month, now: HT.now, calendar: cal)
        // 30D snaps to the 2-h epoch grid (BST midnight = 23:00Z → 22:00Z).
        let monthMidnight = cal.date(byAdding: .day, value: -29, to: day.start)!
        #expect(month.count == 360 && month.start <= monthMidnight
            && month.start > monthMidnight.addingTimeInterval(-7_200))
        #expect(month.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 7_200) == 0)
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
        let gb = HT.london("en_GB"), us = HT.london
        let day = HistoryWindow.make(.day, now: HT.now, calendar: us)
        #expect(HistoryText.title(day, now: HT.now, calendar: gb) == "Thursday, 24 September")
        #expect(HistoryText.title(day, now: HT.now, calendar: us) == "Thursday, 24 September")
        let week = HistoryWindow.make(.week, now: HT.now, calendar: us)
        #expect(HistoryText.title(week, now: HT.now, calendar: us) == "18 – 24 September")
        let month = HistoryWindow.make(.month, now: HT.now, calendar: us)
        #expect(HistoryText.title(month, now: HT.now, calendar: us) == "26 August – 24 September")
        let live = HistoryWindow.make(.live, now: HT.now, calendar: us)
        #expect(HistoryText.title(live, now: HT.now, calendar: gb) == "Last 60 seconds")
        #expect(HistoryText.laneValue(.cpuUsage, 0.8, units: UnitPreferences()) == "80%")
        #expect(HistoryText.laneValue(.netRx, 6_000_000, units: UnitPreferences()) == "6.0 MB/s")
        #expect(HistoryText.laneValue(.socTemp, 76, units: UnitPreferences()) == "76°C")
        #expect(HistoryText.laneValue(.packageWatts, 42.2, units: UnitPreferences()) == "42.2 W")
        #expect(HistoryText.topProcess(HT.share("Xcode", 812), metric: .cpu, units: UnitPreferences())
            == "Xcode · 812% CPU")
    }

    @Test func axisDayStartsSitAtTheirFraction() {
        let week = HistoryWindow.make(.week, now: HT.now, calendar: HT.london)
        let labels = HistoryText.axisLabels(week, calendar: HT.london)!
        #expect(labels.map(\.text) == ["Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
        #expect(abs(labels.last!.fraction - 6.0 / 7.0) < 0.01)                // Thu ≈ 6/7, nothing at `now`
        #expect(labels.first!.fraction == 0)
        let month = HistoryWindow.make(.month, now: HT.now, calendar: HT.london)
        let m = HistoryText.axisLabels(month, calendar: HT.london)!
        #expect(m.map(\.text) == ["27 Aug", "3 Sep", "10 Sep", "17 Sep", "24 Sep"])
        #expect(abs(m.last!.fraction - 29.0 / 30.0) < 0.01)
        let day = HistoryWindow.make(.day, now: HT.now, calendar: HT.london)
        let d = HistoryText.axisLabels(day, calendar: HT.london)!
        #expect(d.first?.text == "00:00" && d.last?.text == "24:00" && d.last?.fraction == 1)
        #expect(HistoryText.axisLabels(HistoryWindow.make(.hour, now: HT.now, calendar: HT.london),
                                       calendar: HT.london) == nil)
    }

    @Test func notesMatchDesignCopy() {
        let build = HistoryEvent(kind: .runawayApp, start: HT.now, end: HT.now.addingTimeInterval(600), level: .elevated,
                                 label: "Xcode build")
        let fair = HistoryEvent(kind: .thermalPressure, start: HT.now, end: HT.now.addingTimeInterval(900),
                                level: .elevated, peak: 1, label: "")
        let note = HistoryText.note([fair, build], at: HT.now.addingTimeInterval(60), bucket: 300,
                                    openEnd: HT.now.addingTimeInterval(900), socPeak: { _ in 88 })
        #expect(note == "CPU spike from an Xcode build. SoC reached 88°C; thermal pressure went to Fair.")
        let byApp = HistoryEvent(kind: .runawayApp, start: HT.now, level: .elevated,
                                 app: AppIdentity(key: HT.share("Safari", 1).id, displayName: "Safari"), label: "")
        #expect(HistoryText.note([byApp], at: HT.now, bucket: 300, openEnd: HT.now.addingTimeInterval(300))
            == "CPU spike from Safari.")
        #expect(HistoryText.note([build], at: HT.now.addingTimeInterval(3_600), bucket: 300, openEnd: HT.now)
            == "Nothing unusual in this window.")
        let chip = HistoryEvent(start: HT.now, label: "Xcode build")
        #expect(HistoryText.chipLabel(chip, range: .day, calendar: HT.london) == "Xcode build · 14:32")
        // Ruling: 7D/30D chips and the At time carry the weekday.
        #expect(HistoryText.chipLabel(chip, range: .week, calendar: HT.london) == "Xcode build · Thu 14:32")
        #expect(HistoryText.moment(HT.now, range: .month, calendar: HT.london) == "Thu 14:32")
        #expect(HistoryText.moment(HT.now, range: .hour, calendar: HT.london) == "14:32")
    }

    @Test func notPersistentBanner() {
        #expect(HistoryText.persistenceBanner(persistent: true) == nil)
        #expect(HistoryText.persistenceBanner(persistent: false)?.hasPrefix("History isn’t being saved — ") == true)
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

    @Test func bandsFromEventsAndMemoryLevels() {
        let w = HistoryWindow.make(.day, now: HT.now, calendar: HT.london)
        let fair = HistoryEvent(kind: .thermalPressure, start: w.time(at: 10), end: w.time(at: 20), level: .elevated,
                                peak: Double(ThermalPressure.fair.rawValue))
        let paused = HistoryEvent(kind: .samplingPaused, start: w.time(at: 50), end: w.time(at: 62), level: .calm)
        let memEvent = HistoryEvent(kind: .memoryPressure, start: w.time(at: 5), end: w.time(at: 6), level: .critical)
        let noSeries = HistoryBand.layout([fair, paused, memEvent, HistoryEvent(kind: .appEpisode, start: w.time(at: 1))],
                                          memoryLevels: [], window: w, width: 287, openEnd: w.dataEnd)
        #expect(noSeries.map(\.kind) == [.fair, .paused, .memoryCritical])  // critical memory draws red
        #expect(noSeries[0].x0 == 10 && noSeries[0].x1 == 20)
        // ICR-12 levels: 1 normal, 2 warning, 4 critical (bucket averages): > 1 amber, > 2.5 red; events ignored.
        var levels = [Double?](repeating: 1, count: w.count)
        for i in 100..<110 { levels[i] = 2 }
        for i in 110..<115 { levels[i] = 3.2 }
        let series = HistoryBand.layout([memEvent], memoryLevels: levels, window: w, width: 287, openEnd: w.dataEnd)
        #expect(series.map(\.kind) == [.memory, .memoryCritical])
        #expect(HistoryBandKind.memoryCritical.fill == HistoryBandKind.critical.fill)
        #expect(HistoryBandKind.memory(level: 1.0) == nil && HistoryBandKind.memory(level: 2.6) == .memoryCritical)
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
    @Test func storedRangesStartAtLatestUnpinnedWithoutLiveBadge() {
        let m = HT.model(.day)
        #expect(!m.pinned)
        #expect(m.cursor == m.window.latest && m.isAtLatest)
        #expect(!m.showsLiveBadge)                                          // "Now", no badge (ruling a)
        m.step(-1)
        #expect(m.cursor == m.window.latest - 1 && !m.pinned)
        m.step(1)
        m.step(1)                                                           // clamped at the newest bucket
        #expect(m.cursor == m.window.latest)
        #expect(m.cursorLabel == HistoryText.moment(m.window.time(at: m.window.latest), range: .day,
                                                    calendar: HT.london))
    }

    @Test func arrowStepsOneBucketAndClamps() {
        let m = HT.model(.day)
        m.scrub(to: 0, interactive: false)
        m.step(-1)
        #expect(m.cursor == 0)
        m.step(1)
        #expect(m.cursor == 1)
        m.scrub(to: m.window.count - 1, interactive: false)                // future bucket requested
        #expect(m.cursor == m.window.latest)
        m.step(1)
        #expect(m.cursor == m.window.latest)
    }

    @Test func chipJumpMovesTheCursorToTheEvent() async {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        let e = HistoryEvent(start: m.window.time(at: 42).addingTimeInterval(90), label: "X")
        m.jump(to: e)
        #expect(m.cursor == 42)
        #expect(!m.isScrubbing)
        await waitUntil { m.sharesTime == m.window.time(at: 42) }
        #expect(m.sharesTime == m.window.time(at: 42))
    }

    @Test func livePinsFollowsUnpinsAndRepins() {
        let m = HT.model(.live)
        #expect(m.pinned && m.showsLiveBadge)
        let apps = [AppSample(identity: AppIdentity(key: HT.share("x", 1).id, displayName: "X"), cpuPercent: 80)]
        m.applyLive(series: [:], now: HT.now.addingTimeInterval(1), apps: apps)
        #expect(m.cursor == 59 && m.pinned)
        #expect(m.topShare?.identity.displayName == "X")
        #expect(m.sharesTime == nil)                                       // live apps, not a store query
        m.scrub(to: 40)
        #expect(!m.pinned && !m.showsLiveBadge)
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

    @Test func rangeSwitchResetsCursorRestoringOnlyWhenAsked() {
        let m = HT.model(.day)
        let moment = m.window.time(at: 100)
        m.scrub(to: 100, interactive: false)
        m.select(.week, now: HT.now)
        #expect(m.cursor == m.window.latest)                               // range switch → latest
        m.select(.day, now: HT.now, restoring: moment)                    // first appear restores
        #expect(m.cursor == 100)
        m.select(.day, now: HT.now, restoring: HT.now.addingTimeInterval(-40 * 86_400))
        #expect(m.cursor == m.window.latest)                               // outside the window: ignored
    }

    @Test func scrubToSameBucketIsANoOp() async {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        m.scrub(to: m.cursor)
        m.scrub(to: m.cursor)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await provider.shareTimes.isEmpty)
    }

    @Test func scrubQueriesAreThrottledByTheInjectedClock() async {
        let clock = ManualClock()
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider, clock: clock)
        // 200 scrub events over one simulated second (5 ms apart).
        for i in 0..<200 {
            m.scrub(to: i % 2 == 0 ? 10 + i / 2 : 10 + i / 2)
            clock.advance(0.005)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        m.endScrub()
        clock.advance(0.2)
        let final = m.cursorTime
        await waitUntil { m.sharesTime == final }
        let times = await provider.shareTimes
        #expect(times.count <= 12)                                         // ≤ 10/s + leading + trailing
        #expect(times.count >= 5)
        #expect(times.last == final)                                       // the trailing query = final position
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

    @Test func metricChangeRequeries() async {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        m.metric = .network
        await waitUntil { await provider.shareTimes.count == 2 }
        #expect(await provider.shareTimes.count == 2)                      // ↓ and ↑ summed
    }

    @Test func exportSuccessFailureAndCancel() async {
        let provider = FakeHistoryProvider()
        let m = HT.model(.day, provider: provider)
        // Cancel: nothing exported, no status.
        #expect(await m.export(to: StubDestination(url: nil)) == nil)
        #expect(await provider.exports.isEmpty)
        #expect(m.exportStatus == nil)
        // Success.
        let url = URL(fileURLWithPath: "/tmp/telltale-test.csv")
        let summary = await m.export(to: StubDestination(url: url))
        #expect(summary?.rows == 288)
        let calls = await provider.exports
        #expect(calls.count == 1)
        #expect(calls.first?.0 == .day && calls.first?.1 == m.window.end && calls.first?.2 == url)
        #expect(m.exportStatus == .exported(rows: 288))
        #expect(m.exportStatus?.text == "Exported 288 rows")
        // Failure: inline status with the error's description.
        await provider.failExports()
        #expect(await m.export(to: StubDestination(url: url)) == nil)
        #expect(m.exportStatus == .failed("Disk full"))
        #expect(m.exportStatus?.text == "Export failed: Disk full")
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

    @Test func noDataRegionEndsAtFirstSampleNeverInTheFuture() async {
        // Data present but the store reports no coverage (e.g. before its first flush): no overlay.
        let m = HT.model(.day, provider: SeriesOnlyProvider(from: 0))
        await m.load()
        #expect(m.noDataUntil == nil)
        // Data only from bucket 100: the region ends there.
        let late = HT.model(.day, provider: SeriesOnlyProvider(from: 100))
        await late.load()
        #expect(late.noDataUntil == late.window.time(at: 100))
        // Nothing at all: up to now (the newest bucket's end), not the rest of the day.
        let empty = HT.model(.day, provider: EmptyHistoryProvider())
        await empty.load()
        #expect(empty.noDataUntil == empty.window.dataEnd)
        #expect(empty.noDataUntil! < empty.window.end)
        // Live never shows it.
        #expect(HT.model(.live).noDataUntil == nil)
    }

    @Test func bandAndChipLayoutsAreCached() async {
        let m = HT.model(.day, provider: MockDataProvider(scenario: .calm).history())
        await m.load()
        var measured = 0
        _ = m.chips(width: 800) { _ in measured += 1; return 50 }
        let first = measured
        _ = m.chips(width: 800) { _ in measured += 1; return 50 }
        #expect(measured == first)                                         // same events/window/width: cached
        m.scrub(to: 10, interactive: false)
        _ = m.chips(width: 800) { _ in measured += 1; return 50 }
        #expect(measured == first)                                         // scrubbing doesn't re-layout
        _ = m.legendKinds                                                  // width-free: doesn't evict the cache
        _ = m.chips(width: 800) { _ in measured += 1; return 50 }
        #expect(measured == first)
        _ = m.chips(width: 700) { _ in measured += 1; return 50 }
        #expect(measured > first)
    }

    @Test func layoutCacheInvalidatesOnRangeChange() async {
        let m = HT.model(.day, provider: MockDataProvider(scenario: .calm).history())
        await m.load()
        let dayChips = m.chips(width: 800) { _ in 50 }
        #expect(!dayChips.isEmpty)
        m.select(.week, now: HT.now)
        #expect(m.chips(width: 800) { _ in 50 }.isEmpty)                  // new window, events not loaded yet
        await m.load()
        let weekChips = m.chips(width: 800) { _ in 50 }
        #expect(!weekChips.isEmpty && weekChips != dayChips)
        #expect(weekChips.allSatisfy { $0.text.contains(" · ") && $0.text.split(separator: " ").count >= 4 })
    }
}
