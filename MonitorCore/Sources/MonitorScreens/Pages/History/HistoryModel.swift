import Dispatch
import Foundation
import MonitorLive
import MonitorModel
import Observation
import os

// DESIGN §3.13 History: range windows, lanes, events, the scrub cursor (Live pins it to now), the "At" treemap
// (`appShares(at: cursor)`, throttled ≤ 10/s while scrubbing; range change cancels in-flight queries) and CSV export.

/// Buckets of one History range. 24H/7D/30D are calendar-aligned (the 24H axis is `00:00 … 24:00` and its title
/// the day, DESIGN §2.12/§3.13); 1H and Live end now. `latest` is the bucket containing now.
public struct HistoryWindow: Equatable, Sendable {
    public var range: HistoryRange
    public var start: Date
    public var bucket: TimeInterval
    public var count: Int
    public var latest: Int

    public var end: Date { start.addingTimeInterval(bucket * Double(count)) }

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
            let end = (now.timeIntervalSince1970 / bucket).rounded(.up) * bucket
            // Store buckets are labelled by their start (1H: last bucket starts at end − 15 s); Live points are the
            // samples themselves, the newest at `now` → the last slot.
            let span = range == .live ? Double(count - 1) : Double(count)
            return HistoryWindow(range: range, start: Date(timeIntervalSince1970: end - bucket * span),
                                 bucket: bucket, count: count, latest: count - 1)
        case .day, .week, .month:
            let days = range == .day ? 1 : (range == .week ? 7 : 30)
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            let count = Int((Double(days) * 86_400 / bucket).rounded())
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

    /// The scheduled trailing fire ran.
    public mutating func firedScheduled(at now: Double) {
        scheduled = nil
        lastFire = now
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

@MainActor @Observable
public final class HistoryModel {
    public enum LoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public private(set) var window: HistoryWindow
    /// Lane values per bucket (`window.count` long; nil = gap).
    public private(set) var lanes: [HistoryMetric: [Double?]] = [:]
    public private(set) var events: [HistoryEvent] = []
    public private(set) var coverage: DateInterval?
    public private(set) var coverageKnown = false
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
    public private(set) var exportStatus: String?

    /// Lane metrics (DESIGN §3.13).
    public nonisolated static let laneMetrics: [HistoryMetric] = [.cpuUsage, .gpuUsage, .memPressure, .netRx, .socTemp,
                                                                   .packageWatts]
    public nonisolated static let shareLimit = 24
    /// Bands and chips come from these event kinds.
    @ObservationIgnored public var provider: any HistoryProvider
    @ObservationIgnored public var calendar: Calendar
    @ObservationIgnored private var throttle = ShareQueryThrottle()
    @ObservationIgnored private let clock: @Sendable () -> Double
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    @ObservationIgnored private var trailingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var liveApps: [AppSample] = []
    /// Unpinned Live cursor keeps its timestamp while the window moves.
    @ObservationIgnored private var liveCursorTime: Date?
    /// Number of provider share queries started (tests: ≤ 10/s).
    @ObservationIgnored public private(set) var shareQueryCount = 0

    public init(range: HistoryRange = .day, now: Date = Date(), provider: any HistoryProvider,
                calendar: Calendar = .current, clock: @escaping @Sendable () -> Double = HistoryModel.monotonicSeconds) {
        self.provider = provider
        self.calendar = calendar
        self.clock = clock
        let w = HistoryWindow.make(range, now: now, calendar: calendar)
        window = w
        cursor = w.latest
        pinned = range == .live
    }

    public nonisolated static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    public var range: HistoryRange { window.range }

    /// End of the leading "No data yet" region (DESIGN §3.15 partial history), nil when there is none. The data
    /// itself wins over `coverage()`: the region ends at the first bucket with any lane value (a store that reports
    /// no/late coverage — e.g. before its first flush — never hides samples that are there).
    public var noDataUntil: Date? {
        guard range != .live, loadState == .loaded else { return nil }
        let firstIndex = lanes.values.compactMap { $0.firstIndex { $0 != nil } }.min()
        let firstData = firstIndex.map { window.time(at: $0) }
        let boundary: Date
        switch (firstData, coverage?.start) {
        case let (d?, c?): boundary = min(d, c)
        case let (d?, nil): boundary = d
        case let (nil, c?): boundary = c
        case (nil, nil): return window.end                                   // empty history
        }
        guard boundary > window.start.addingTimeInterval(window.bucket * 0.5) else { return nil }
        return min(boundary, window.end)
    }
    public var cursorTime: Date { window.time(at: cursor) }
    public var isAtLatest: Bool { cursor == window.latest }

    // MARK: Range

    /// Switches range: new window, cursor at the latest bucket (pinned on Live), cancels in-flight loads/queries.
    public func select(_ range: HistoryRange, now: Date) {
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
        shares = []
        otherCount = 0
        sharesTime = nil
        loadState = range == .live ? .loaded : .loading
    }

    /// Loads series, events and coverage for a stored range, then the shares at the cursor.
    public func load() async {
        guard range != .live else { return }
        let gen = generation
        let w = window
        let provider = provider
        do {
            async let series = provider.series(Self.laneMetrics, range: w.range, end: w.end)
            async let evts = provider.events(in: DateInterval(start: w.start, end: w.end))
            async let cov = provider.coverage()
            let (s, e, c) = try await (series, evts, cov)
            guard gen == generation, !Task.isCancelled else { return }
            apply(series: s, events: e, coverage: c)
            await queryShares(at: cursorTime, generation: gen)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            loadState = .failed("\(error)")
        }
    }

    /// `load()` in a task owned by the model (a range change cancels it).
    public func startLoading() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    /// Snapshot renders (no run-loop wait): performs the load off the main actor and waits up to `timeout`.
    public func loadSynchronously(timeout: TimeInterval = 2) {
        guard range != .live else { return }
        let w = window, provider = provider, metric = metric
        let t = cursorTime
        typealias Payload = ([HistoryMetric: [SeriesPoint]], [HistoryEvent], DateInterval?, [[AppShare]])
        let box = OSAllocatedUnfairLock<Result<Payload, any Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let s = try await provider.series(Self.laneMetrics, range: w.range, end: w.end)
                let e = try await provider.events(in: DateInterval(start: w.start, end: w.end))
                let c = try await provider.coverage()
                var sh: [[AppShare]] = []
                for m in metric.appMetrics {
                    sh.append(try await provider.appShares(at: t, metric: m, range: w.range, limit: Self.shareLimit))
                }
                let payload: Payload = (s, e, c, sh)
                box.withLock { $0 = .success(payload) }
            } catch {
                box.withLock { $0 = .failure(error) }
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let result = box.withLock({ $0 }) else { return }
        switch result {
        case .success(let (s, e, c, sh)):
            apply(series: s, events: e, coverage: c)
            setShares(sh, at: t)
        case .failure(let error):
            loadState = .failed("\(error)")
        }
    }

    private func apply(series: [HistoryMetric: [SeriesPoint]], events: [HistoryEvent], coverage: DateInterval?) {
        var out: [HistoryMetric: [Double?]] = [:]
        for m in Self.laneMetrics {
            out[m] = Self.bucketed(series[m] ?? [], window: window)
        }
        lanes = out
        self.events = events.sorted { $0.start < $1.start }
        self.coverage = coverage
        coverageKnown = true
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
    public func applyLive(series: [HistoryMetric: [SeriesPoint]], now: Date, apps: [AppSample],
                          coverage: DateInterval? = nil) {
        guard range == .live else { return }
        window = HistoryWindow.make(.live, now: now, calendar: calendar)
        var out: [HistoryMetric: [Double?]] = [:]
        for m in Self.laneMetrics { out[m] = Self.bucketed(series[m] ?? [], window: window) }
        lanes = out
        liveApps = apps
        self.coverage = coverage
        coverageKnown = coverage != nil
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

    /// Moves the cursor (slider, lane drag, ←/→, chip click). Live re-pins on the newest bucket.
    public func scrub(to index: Int, interactive: Bool = true) {
        let i = window.clamp(index)
        if interactive { isScrubbing = true }
        cursor = i
        if range == .live {
            pinned = i == window.latest
            liveCursorTime = pinned ? nil : window.time(at: i)
        }
        requestShares(force: false)
    }

    /// Restores a cursor moment (e.g. `nav.historyScrub` when the page reappears) before `load()`; no query.
    public func restoreCursor(to date: Date) {
        guard range != .live, date >= window.start, date < window.end else { return }
        cursor = window.index(of: date)
    }

    public func endScrub() {
        isScrubbing = false
    }

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
            let wait = max(0, at - clock())
            let gen = generation
            trailingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
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
        shareQueryCount += 1
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
        shares = r.shares
        otherCount = r.otherCount
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

    /// Export CSV (DESIGN §3.13): asks for a destination (`NSSavePanel` in the app), then `exportCSV` of the
    /// current range at display resolution.
    @discardableResult
    public func export(destination: @MainActor () async -> URL?) async -> ExportSummary? {
        guard let url = await destination() else { return nil }
        do {
            let summary = try await provider.exportCSV(range: range, end: window.end, to: url)
            exportStatus = "Exported \(summary.rows.formatted()) rows"
            return summary
        } catch {
            exportStatus = "Export failed"
            return nil
        }
    }
}
