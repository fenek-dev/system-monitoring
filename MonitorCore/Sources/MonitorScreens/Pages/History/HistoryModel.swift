import Dispatch
import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import Observation

// DESIGN §3.13 History: range windows, lanes, events, the scrub cursor (Live pins it to now), the "At" treemap
// (`appShares(at: cursor)`, throttled ≤ 10/s while scrubbing; range change cancels in-flight queries) and CSV export.

/// Buckets of one History range. 24H/7D/30D are calendar-aligned in the injected calendar (the 24H axis is
/// `00:00 … 24:00` and its title the day, DESIGN §2.12/§3.13); 1H and Live end now. `latest` = bucket containing now.
public struct HistoryWindow: Equatable, Sendable {
    public var range: HistoryRange
    public var start: Date
    public var bucket: TimeInterval
    public var count: Int
    public var latest: Int

    public init(range: HistoryRange, start: Date, bucket: TimeInterval, count: Int, latest: Int) {
        self.range = range
        self.start = start
        self.bucket = bucket
        self.count = count
        self.latest = latest
    }

    public var end: Date { start.addingTimeInterval(bucket * Double(count)) }

    /// End of the newest bucket: the stored ranges' "now" (never the ticking clock).
    public var dataEnd: Date { start.addingTimeInterval(bucket * Double(latest + 1)) }

    /// First local day of a calendar-aligned window (`start` may sit up to one bucket before local midnight
    /// after snapping to the store grid).
    public func firstDay(_ calendar: Calendar) -> Date {
        calendar.startOfDay(for: start.addingTimeInterval(bucket))
    }

    public func time(at index: Int) -> Date { start.addingTimeInterval(bucket * Double(clamp(index))) }

    /// Bucket containing `date` (clamped to the window).
    public func index(of date: Date) -> Int { clamp(Int((date.timeIntervalSince(start) / bucket).rounded(.down))) }

    public func clamp(_ i: Int) -> Int { min(max(i, 0), max(count - 1, 0)) }

    /// Fraction 0…1 of `date` across the chart (x = i/(N−1), like the sparklines).
    public func fraction(of date: Date) -> Double {
        guard count > 1 else { return 0 }
        return min(max(date.timeIntervalSince(start) / (bucket * Double(count - 1)), 0), 1)
    }

    public static func make(_ range: HistoryRange, now: Date, calendar: Calendar) -> HistoryWindow {
        let bucket = Double(range.displayBucket.components.seconds)
        switch range {
        case .live, .hour:
            let count = Int((Double(range.duration?.components.seconds ?? 60) / bucket).rounded())
            // The newest bucket is the one containing `now` (labelled by its start, like the store's buckets).
            let newest = (now.timeIntervalSince1970 / bucket).rounded(.down) * bucket
            return HistoryWindow(range: range, start: Date(timeIntervalSince1970: newest - bucket * Double(count - 1)),
                                 bucket: bucket, count: count, latest: count - 1)
        case .day, .week, .month:
            let days = range == .day ? 1 : (range == .week ? 7 : 30)
            let today = calendar.startOfDay(for: now)
            let midnight = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            // Snap to the store's epoch-aligned bucket grid (30D: 2-h buckets vs. an odd UTC offset would put the
            // newest local bucket between two stored ones and leave it empty); at most one bucket earlier.
            let start = Date(timeIntervalSince1970: (midnight.timeIntervalSince1970 / bucket).rounded(.down) * bucket)
            // Cover through the next local midnight (DST days are 23/25 h; the snap adds up to one bucket), so the
            // bucket containing `now` always exists.
            let localEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
            let count = max(1, Int((localEnd.timeIntervalSince(start) / bucket).rounded(.up)))
            var w = HistoryWindow(range: range, start: start, bucket: bucket, count: count, latest: 0)
            w.latest = w.index(of: now)
            return w
        }
    }
}

/// Leading + trailing throttle (ARCHITECTURE §7 scrub throttling): at most one fire per `interval`; requests
/// inside the interval coalesce into one trailing fire at `lastFire + interval`.
public struct ShareQueryThrottle: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case fireNow, schedule(at: Double), coalesce }

    public var interval: Double
    public private(set) var lastFire: Double?
    public private(set) var scheduled: Double?

    public init(interval: Double = 0.1) { self.interval = interval }

    public mutating func request(at now: Double) -> Decision {
        if scheduled != nil { return .coalesce }
        if let last = lastFire, now - last < interval {
            scheduled = last + interval
            return .schedule(at: last + interval)
        }
        lastFire = now
        return .fireNow
    }

    /// The scheduled trailing fire ran (counted at its scheduled time, so an early wake-up can't raise the rate).
    public mutating func firedScheduled(at now: Double) {
        lastFire = max(now, scheduled ?? now)
        scheduled = nil
    }

    public mutating func reset() {
        lastFire = nil
        scheduled = nil
    }
}

/// Treemap metric control (DESIGN §3.13 [CPU | GPU | Memory | Network | Disk | Energy]).
public enum TreemapMetric: String, CaseIterable, Sendable {
    case cpu, gpu, memory, network, disk, energy

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .energy: "Energy"
        }
    }

    /// Store/app metrics summed for the share (network ↓+↑, disk R+W).
    public var appMetrics: [AppMetric] {
        switch self {
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .network: [.netRx, .netTx]
        case .disk: [.diskRead, .diskWrite]
        case .energy: [.energy]
        }
    }

    /// The metric handed to `TTTreemap` (color + value format).
    public var treemapMetric: AppMetric { appMetrics[0] }
}

/// Where Export CSV writes (DESIGN §3.13). The app runs an `NSSavePanel` sheet on the dashboard window
/// (`SavePanelExportDestination`); tests inject a stub.
public protocol HistoryExportDestination: Sendable {
    /// nil = cancelled.
    @MainActor func chooseDestination(suggestedName: String) async -> URL?
}

/// Inline status under Export CSV.
public enum HistoryExportStatus: Equatable, Sendable {
    case exported(rows: Int)
    case failed(String)

    public var text: String {
        switch self {
        case .exported(let rows): "Exported \(rows.formatted()) rows"
        case .failed(let why): "Export failed: \(why)"
        }
    }
}

@MainActor @Observable
public final class HistoryModel {
    public enum LoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public private(set) var window: HistoryWindow
    /// Values per bucket (`window.count` long; nil = gap) for the lanes and `memPressureLevel` (bands).
    public private(set) var lanes: [HistoryMetric: [Double?]] = [:]
    public private(set) var events: [HistoryEvent] = []
    public private(set) var coverage: DateInterval?
    public private(set) var loadState: LoadState = .idle
    public private(set) var cursor: Int
    public private(set) var pinned: Bool
    public private(set) var isScrubbing = false
    public var metric: TreemapMetric = .cpu {
        didSet { if metric != oldValue { requestShares(force: true) } }
    }
    /// Treemap data for the cursor bucket (named ≥ 2 % + Other).
    public private(set) var shares: [AppShare] = []
    public private(set) var otherCount = 0
    /// Cursor time the current `shares` belong to (nil = live apps).
    public private(set) var sharesTime: Date?
    public private(set) var exportStatus: HistoryExportStatus?

    /// Lane metrics (DESIGN §3.13).
    public nonisolated static let laneMetrics: [HistoryMetric] = [.cpuUsage, .gpuUsage, .memPressure, .netRx, .socTemp,
                                                                   .packageWatts]
    /// Queried series: the lanes plus ICR-12 `memPressureLevel` (memory bands).
    public nonisolated static let seriesMetrics: [HistoryMetric] = laneMetrics + [.memPressureLevel]
    public nonisolated static let shareLimit = 24

    @ObservationIgnored public var provider: any HistoryProvider
    /// The page's calendar (environment time zone + locale). Changing it drops the layout caches; the page then
    /// re-selects the range so the window is rebuilt in the new zone.
    @ObservationIgnored public var calendar: Calendar {
        didSet {
            bandCache = nil
            chipCache = nil
        }
    }
    /// Band layouts computed (tests: the cache is hit on scrub, missed on range/width changes).
    @ObservationIgnored public private(set) var bandLayoutCount = 0
    @ObservationIgnored private var throttle = ShareQueryThrottle()
    @ObservationIgnored private let clock: @Sendable () -> Double
    @ObservationIgnored private let sleepUntil: @Sendable (Double) async -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    @ObservationIgnored private var trailingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var liveApps: [AppSample] = []
    /// Unpinned Live cursor keeps its timestamp while the window moves.
    @ObservationIgnored private var liveCursorTime: Date?
    @ObservationIgnored private var bandCache: (key: LayoutKey, bands: [HistoryBand])?
    @ObservationIgnored private var chipCache: (key: LayoutKey, chips: [HistoryChip])?

    private struct LayoutKey: Equatable {
        var events: [HistoryEvent]
        var memory: [Double?]
        var window: HistoryWindow
        var width: CGFloat
    }

    /// - Parameters:
    ///   - calendar: the environment's calendar/time zone (London in snapshots) — never `Calendar.current`.
    ///   - clock/sleepUntil: monotonic seconds and "sleep until" for the scrub throttle (tests inject a manual clock).
    public init(range: HistoryRange = .day, now: Date, provider: any HistoryProvider, calendar: Calendar,
                clock: @escaping @Sendable () -> Double = HistoryModel.monotonicSeconds,
                sleepUntil: @escaping @Sendable (Double) async -> Void = HistoryModel.sleepUntilMonotonic) {
        self.provider = provider
        self.calendar = calendar
        self.clock = clock
        self.sleepUntil = sleepUntil
        let w = HistoryWindow.make(range, now: now, calendar: calendar)
        window = w
        cursor = w.latest
        pinned = range == .live
    }

    public nonisolated static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    public nonisolated static func sleepUntilMonotonic(_ t: Double) async {
        let wait = t - monotonicSeconds()
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    public var range: HistoryRange { window.range }
    public var cursorTime: Date { window.time(at: cursor) }
    public var isAtLatest: Bool { cursor == window.latest }
    /// "Now" + Live badge only while pinned — i.e. only on the Live range (ruling).
    public var showsLiveBadge: Bool { range == .live && pinned }

    /// End of the leading "No data yet" region: [window.start, first stored sample), never into the future
    /// (DESIGN §3.15). Data wins over `coverage()` (a store reporting no/late coverage never hides samples).
    public var noDataUntil: Date? {
        guard range != .live, loadState == .loaded else { return nil }
        let firstIndex = Self.laneMetrics.compactMap { m in lanes[m]?.firstIndex { $0 != nil } }.min()
        let firstData = firstIndex.map { window.time(at: $0) }
        let boundary: Date
        switch (firstData, coverage?.start) {
        case let (d?, c?): boundary = min(d, c)
        case let (d?, nil): boundary = d
        case let (nil, c?): boundary = c
        case (nil, nil): boundary = window.dataEnd                          // empty: up to now, not beyond
        }
        let until = min(boundary, window.dataEnd)
        guard until > window.start.addingTimeInterval(window.bucket * 0.5) else { return nil }
        return until
    }

    // MARK: Range

    /// Switches range: new window, cursor at the latest bucket (pinned on Live), cancels in-flight loads/queries.
    /// `restoring` (first appear only) puts the cursor back on a remembered moment inside the new window.
    public func select(_ range: HistoryRange, now: Date, restoring: Date? = nil) {
        generation += 1
        loadTask?.cancel()
        shareTask?.cancel()
        trailingTask?.cancel()
        throttle.reset()
        window = HistoryWindow.make(range, now: now, calendar: calendar)
        cursor = window.latest
        pinned = range == .live
        liveCursorTime = nil
        isScrubbing = false
        lanes = [:]
        events = []
        coverage = nil
        shares = []
        otherCount = 0
        sharesTime = nil
        loadState = range == .live ? .loaded : .loading
        if let t = restoring, range != .live, t >= window.start, t < window.end {
            cursor = window.index(of: t)
        }
    }

    /// Loads series, events and coverage for a stored range, then the shares at the cursor.
    public func load() async {
        guard range != .live else { return }
        let gen = generation
        let w = window
        let provider = provider
        do {
            async let series = provider.series(Self.seriesMetrics, range: w.range, end: w.end)
            async let evts = provider.events(in: DateInterval(start: w.start, end: w.end))
            async let cov = provider.coverage()
            let (s, e, c) = try await (series, evts, cov)
            guard gen == generation, !Task.isCancelled else { return }
            apply(series: s, events: e, coverage: c)
            await queryShares(at: cursorTime, generation: gen)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    /// `load()` in a task owned by the model (a range change cancels it).
    public func startLoading() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func apply(series: [HistoryMetric: [SeriesPoint]], events: [HistoryEvent], coverage: DateInterval?) {
        var out: [HistoryMetric: [Double?]] = [:]
        for m in Self.seriesMetrics { out[m] = Self.bucketed(series[m] ?? [], window: window) }
        lanes = out
        self.events = events.sorted { $0.start < $1.start }
        self.coverage = coverage
        loadState = .loaded
    }

    /// Places points into the window's buckets by time (robust to providers returning fewer/more points).
    public nonisolated static func bucketed(_ points: [SeriesPoint], window: HistoryWindow) -> [Double?] {
        var values = [Double?](repeating: nil, count: window.count)
        for p in points {
            // Floor: the store's epoch-aligned buckets may be offset from a local-midnight window (30D: 2-h buckets
            // vs. an odd UTC offset); each point lands in the window bucket containing its start.
            let i = Int((p.time.timeIntervalSince(window.start) / window.bucket + 1e-6).rounded(.down))
            guard i >= 0, i < window.count else { continue }
            if let v = p.value, v.isFinite { values[i] = v }
        }
        return values
    }

    // MARK: Live

    /// One Live tick: the last 60 s from the live model. Pinned → cursor on the newest bucket and the treemap
    /// from live apps; unpinned → the cursor keeps its timestamp while the window moves.
    public func applyLive(series: [HistoryMetric: [SeriesPoint]], now: Date, apps: [AppSample]) {
        guard range == .live else { return }
        window = HistoryWindow.make(.live, now: now, calendar: calendar)
        var out: [HistoryMetric: [Double?]] = [:]
        for m in Self.seriesMetrics { out[m] = Self.bucketed(series[m] ?? [], window: window) }
        lanes = out
        liveApps = apps
        loadState = .loaded
        if pinned {
            cursor = window.latest
            setShares(Self.liveShares(apps, metric: metric), at: nil)
        } else if let t = liveCursorTime {
            cursor = window.index(of: t)
        }
    }

    public nonisolated static func liveShares(_ apps: [AppSample], metric: TreemapMetric) -> [[AppShare]] {
        metric.appMetrics.map { m in
            apps.compactMap { a -> AppShare? in
                guard let v = a.value(for: m), v > 0 else { return nil }
                return AppShare(identity: a.identity, value: v, fraction: 0)
            }
        }
    }

    // MARK: Cursor

    /// Moves the cursor (slider, lane drag, ←/→, chip click). Live re-pins on the newest bucket. Same bucket → no-op.
    public func scrub(to index: Int, interactive: Bool = true) {
        // Never past the newest bucket: later ones are the future on the calendar-aligned ranges.
        let i = min(window.clamp(index), window.latest)
        if interactive, !isScrubbing { isScrubbing = true }
        guard i != cursor else { return }
        cursor = i
        if range == .live {
            pinned = i == window.latest
            liveCursorTime = pinned ? nil : window.time(at: i)
        }
        requestShares(force: false)
    }

    public func endScrub() {
        if isScrubbing { isScrubbing = false }
    }

    /// ← / → (DESIGN §3.13): one bucket.
    public func step(_ delta: Int) { scrub(to: cursor + delta, interactive: false) }

    /// Chip click: cursor to the event's start.
    public func jump(to event: HistoryEvent) { scrub(to: window.index(of: event.start), interactive: false) }

    /// Re-selecting Live re-pins.
    public func repin() {
        guard range == .live else { return }
        pinned = true
        liveCursorTime = nil
        cursor = window.latest
        setShares(Self.liveShares(liveApps, metric: metric), at: nil)
    }

    // MARK: Layout caches (bands/chips re-laid out only when events, memory levels, window or width change)

    public func bands(width: CGFloat) -> [HistoryBand] {
        let key = LayoutKey(events: events, memory: lanes[.memPressureLevel] ?? [], window: window, width: width)
        if let c = bandCache, c.key == key { return c.bands }
        let bands = HistoryBand.layout(events, memoryLevels: key.memory, window: window, width: width,
                                       openEnd: window.dataEnd)
        bandCache = (key, bands)
        bandLayoutCount += 1
        return bands
    }

    /// Band kinds present in the range (legend), width-independent — never touches the layout cache.
    public var legendKinds: [HistoryBandKind] {
        let present = Set(HistoryBand.layout(events, memoryLevels: lanes[.memPressureLevel] ?? [], window: window,
                                             width: 1, openEnd: window.dataEnd).map(\.kind))
        return HistoryBandKind.allCases.filter(present.contains)
    }

    public func chips(width: CGFloat, measure: (String) -> CGFloat) -> [HistoryChip] {
        let key = LayoutKey(events: events, memory: [], window: window, width: width)
        if let c = chipCache, c.key == key { return c.chips }
        let (range, calendar) = (range, calendar)
        let chips = HistoryChip.layout(events, window: window, width: width,
                                       label: { HistoryText.chipLabel($0, range: range, calendar: calendar) },
                                       measure: measure)
        chipCache = (key, chips)
        return chips
    }

    /// Cursor time for the "At" card: "14:35", or "Tue 09:10" on 7D/30D (ruling: day-less times are ambiguous there).
    public var cursorLabel: String { HistoryText.moment(cursorTime, range: range, calendar: calendar) }

    /// The "At" note for the cursor bucket (DESIGN §3.13), with the SoC peak over each thermal episode.
    public func note(units: UnitPreferences) -> String {
        HistoryText.note(events, at: cursorTime, bucket: window.bucket, openEnd: window.dataEnd, units: units,
                         socPeak: { [lanes, window] interval in
                             guard let soc = lanes[.socTemp] else { return nil }
                             let a = window.index(of: interval.start), b = window.index(of: interval.end)
                             return soc[min(a, b)...max(a, b)].compactMap { $0 }.max()
                         })
    }

    // MARK: Shares

    private func requestShares(force: Bool) {
        if range == .live && pinned {
            setShares(Self.liveShares(liveApps, metric: metric), at: nil)
            return
        }
        if force {
            throttle.reset()
            trailingTask?.cancel()
        }
        switch throttle.request(at: clock()) {
        case .fireNow:
            fireShareQuery()
        case .schedule(let at):
            let gen = generation
            let sleepUntil = sleepUntil
            trailingTask = Task { [weak self] in
                await sleepUntil(at)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.throttle.firedScheduled(at: self.clock())
                self.fireShareQuery()
            }
        case .coalesce:
            break
        }
    }

    private func fireShareQuery() {
        let gen = generation
        let t = cursorTime
        shareTask?.cancel()
        shareTask = Task { [weak self] in await self?.queryShares(at: t, generation: gen) }
    }

    private func queryShares(at time: Date, generation gen: Int) async {
        let provider = provider, metric = metric, range = range
        do {
            var results: [[AppShare]] = []
            for m in metric.appMetrics {
                results.append(try await provider.appShares(at: time, metric: m, range: range, limit: Self.shareLimit))
            }
            guard gen == generation, !Task.isCancelled else { return }
            setShares(results, at: time)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            setShares([], at: time)
        }
    }

    private func setShares(_ raw: [[AppShare]], at time: Date?) {
        let r = Self.treemapShares(Self.sumByApp(raw))
        if shares != r.shares { shares = r.shares }
        if otherCount != r.otherCount { otherCount = r.otherCount }
        sharesTime = time
    }

    /// Sums per-app values across metric lists (network ↓+↑, disk R+W).
    public nonisolated static func sumByApp(_ lists: [[AppShare]]) -> [AppShare] {
        var order: [AppKey] = []
        var by: [AppKey: AppShare] = [:]
        for list in lists {
            for s in list {
                if var e = by[s.id] {
                    e.value += s.value
                    by[s.id] = e
                } else {
                    order.append(s.id)
                    by[s.id] = s
                }
            }
        }
        return order.compactMap { by[$0] }
    }

    /// DESIGN §2.28: named apps with ≥ 2 % share (descending), the rest (and any `.other`) as one "Other" last.
    public nonisolated static func treemapShares(_ raw: [AppShare]) -> (shares: [AppShare], otherCount: Int) {
        let positive = raw.filter { $0.value > 0 && $0.value.isFinite }
        let total = positive.reduce(0) { $0 + $1.value }
        guard total > 0 else { return ([], 0) }
        var named: [AppShare] = []
        var otherValue = 0.0
        var otherCount = 0
        for s in positive {
            if s.id.kind == .other || s.value / total < 0.02 {
                otherValue += s.value
                otherCount += 1
            } else {
                var n = s
                n.fraction = s.value / total
                named.append(n)
            }
        }
        named.sort { $0.value != $1.value ? $0.value > $1.value : $0.identity.displayName < $1.identity.displayName }
        if otherValue > 0 {
            named.append(AppShare(identity: AppIdentity(key: .other, displayName: "Other"), value: otherValue,
                                  fraction: otherValue / total))
        }
        return (named, otherCount)
    }

    /// The top named app at the cursor.
    public var topShare: AppShare? { shares.first { $0.id.kind != .other } }

    // MARK: Export

    /// Export CSV (DESIGN §3.13): asks the destination service, then `exportCSV` of the current range at display
    /// resolution. Status: rows written, or the error's description inline; cancel leaves it unchanged.
    @discardableResult
    public func export(to destination: any HistoryExportDestination) async -> ExportSummary? {
        let name = "Telltale History \(range.label).csv"
        guard let url = await destination.chooseDestination(suggestedName: name) else { return nil }
        do {
            let summary = try await provider.exportCSV(range: range, end: window.end, to: url)
            exportStatus = .exported(rows: summary.rows)
            return summary
        } catch {
            exportStatus = .failed(error.localizedDescription)
            return nil
        }
    }
}
