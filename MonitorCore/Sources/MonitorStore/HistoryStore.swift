import Foundation
import GRDB
import MonitorModel

public struct StoreConfig: Sendable {
    public var flushInterval: Duration
    public var flushMaxRecords: Int
    /// Full resolution for 24 h (ruling).
    public var rawRetention: Duration
    public var minuteRetention: Duration
    public var quarterRetention: Duration
    public var maintenanceInterval: Duration
    public var now: @Sendable () -> Date

    public init(
        flushInterval: Duration = .seconds(30),
        flushMaxRecords: Int = 120,
        rawRetention: Duration = .seconds(86_400),
        minuteRetention: Duration = .seconds(7 * 86_400),
        quarterRetention: Duration = .seconds(30 * 86_400),
        maintenanceInterval: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.flushInterval = flushInterval
        self.flushMaxRecords = flushMaxRecords
        self.rawRetention = rawRetention
        self.minuteRetention = minuteRetention
        self.quarterRetention = quarterRetention
        self.maintenanceInterval = maintenanceInterval
        self.now = now
    }
}

/// SQLite (GRDB, WAL) history: buffered writes, rollups, retention, bucketed range queries, CSV export.
/// No `flushSync`: termination awaits `runtime.shutdown()` (→ `flush()`) via `.terminateLater` (ARCHITECTURE §4).
public actor HistoryStore: HistoryProvider, HistoryRecorder {
    public enum Location: Sendable { case file(URL), inMemory }

    let writer: any DatabaseWriter
    let config: StoreConfig
    let columns: Columns

    private var pendingRecords: [HistoryRecord] = []
    /// Buffered, not yet written (tests).
    var pendingRecordCount: Int { pendingRecords.count }
    private var pendingEvents: [HistoryEvent] = []
    private var lastFlush: Date
    private var maintaining = false
    /// Flushes run strictly in order; `flush()` awaits every earlier write (shutdown relies on it).
    private var writeChain: Task<Void, any Error>?

    public init(location: Location, config: StoreConfig = .init()) throws {
        try self.init(location: location, config: config, columns: .current)
    }

    /// Test seam: extra/fewer metric columns than today's enums.
    init(location: Location, config: StoreConfig, systemColumns: [String], appColumns: [String]) throws {
        try self.init(location: location, config: config, columns: Columns(system: systemColumns, app: appColumns))
    }

    private init(location: Location, config: StoreConfig, columns: Columns) throws {
        self.writer = try StoreDatabase.open(location, columns: columns)
        self.config = config
        self.columns = columns
        self.lastFlush = config.now()
        // Maintenance runs on its own timer, never inside append/flush: once at open (catch-up), then every
        // `maintenanceInterval`. `maintenanceInterval <= .zero` disables it (callers run `maintain(now:)`).
        // The task holds the store weakly, so it ends after the store is released.
        let interval = config.maintenanceInterval
        if interval > .zero {
            Task { [weak self] in
                await self?.scheduledMaintenance()
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval, tolerance: interval / 10)
                    guard let self else { return }
                    await self.scheduledMaintenance()
                }
            }
        }
    }

    // MARK: HistoryRecorder

    /// Buffers; on `flushMaxRecords` or `flushInterval` it hands the buffer to the ordered write chain and returns
    /// without waiting for the write. Write failures drop the batch and log a fault (ARCHITECTURE §6).
    public func append(_ batch: RecordBatch) async {
        if let record = batch.record { pendingRecords.append(record) }
        pendingEvents.append(contentsOf: batch.events)
        let now = config.now()
        guard pendingRecords.count >= config.flushMaxRecords
            || now.timeIntervalSince(lastFlush) >= config.flushInterval.timeInterval else { return }
        enqueueFlush()
    }

    /// Writes everything buffered in one transaction, after (and awaiting) every earlier write.
    /// The termination path awaits this (no flushSync).
    public func flush() async throws {
        try await enqueueFlush().value
    }

    @discardableResult
    private func enqueueFlush() -> Task<Void, any Error> {
        lastFlush = config.now()
        let records = pendingRecords
        let events = pendingEvents
        pendingRecords.removeAll(keepingCapacity: true)
        pendingEvents.removeAll(keepingCapacity: true)
        let previous = writeChain
        let writer = self.writer
        let task = Task {
            _ = await previous?.result
            guard !records.isEmpty || !events.isEmpty else { return }
            do {
                try await writer.write { db in try RecordWriter.write(records, events, db) }
            } catch {
                StoreDatabase.log.fault("dropped \(records.count) records, \(events.count) events: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        writeChain = task
        return task
    }

    /// Flush, then rollups (completed buckets) and retention in one transaction, then incremental vacuum.
    public func maintain(now: Date) async throws {
        guard !maintaining else { return }
        maintaining = true
        defer { maintaining = false }
        try await flush()
        let columns = self.columns
        let nowMs = now.unixMs
        let cutoffs = Retention.cutoffs(nowMs: nowMs, config: config)
        try await writer.write { db in
            try Rollup.run(db, columns: columns, nowMs: nowMs, rawCutoff: cutoffs.raw, minuteCutoff: cutoffs.minute)
            try Retention.run(db, cutoffs)
        }
        try await writer.writeWithoutTransaction { db in try Retention.vacuumIfNeeded(db) }
        maintenanceRuns += 1
    }

    private func scheduledMaintenance() async {
        do { try await maintain(now: config.now()) } catch {
            StoreDatabase.log.fault("history maintenance failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Completed maintenance passes (tests).
    private(set) var maintenanceRuns = 0

    /// Awaits every write handed to the chain so far, without flushing the buffer (tests).
    func writesSettled() async {
        _ = await writeChain?.result
    }

    // MARK: HistoryProvider

    public func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [HistoryMetric: [SeriesPoint]] {
        guard !metrics.isEmpty else { return [:] }
        let level = level(for: range, end: end)
        let buckets = Self.buckets(range: range, end: end, bucket: bucket, level: level)
        let window = buckets.window(end: end)
        let cols = metrics.map(\.rawValue)
        let rows = try await writer.read { db in
            try Queries.systemBuckets(db, cols: cols, level: level, window: window, width: buckets.width)
        }
        var result: [HistoryMetric: [SeriesPoint]] = [:]
        for (i, metric) in metrics.enumerated() { result[metric] = Queries.points(buckets, rows, column: i) }
        return result
    }

    /// Display buckets: `bucket` (default `range.displayBucket`) rounded to a multiple of the level's resolution.
    static func buckets(range: HistoryRange, end: Date, bucket: Duration?, level: Level) -> Buckets {
        let width = Buckets.width(requested: (bucket ?? range.displayBucket).milliseconds, resolution: level.resolutionMs)
        return Buckets(end: end, duration: range.span, width: width)
    }

    /// The range's level (§5.9 routing), coarsened when the window starts before that level's retention
    /// (e.g. 24H ending 12 h ago reads 1 m rollups).
    func level(for range: HistoryRange, end: Date) -> Level {
        Level.coarser(Level.forRange(range), level(forIntervalStart: end - range.span.timeInterval))
    }

    /// Per bucket: the app's mean over the bucket's samples (samples without the app count as 0);
    /// gap where the bucket has no system rows; nil where the app's metric was unavailable.
    public func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?)
        async throws -> [AppMetric: [SeriesPoint]] {
        guard !metrics.isEmpty else { return [:] }
        let level = level(for: range, end: end)
        let buckets = Self.buckets(range: range, end: end, bucket: bucket, level: level)
        let window = buckets.window(end: end)
        let cols = metrics.map(\.rawValue)
        let rows = try await writer.read { db in
            try Queries.appBuckets(db, key: app, cols: cols, level: level, window: window, width: buckets.width)
        }
        var result: [AppMetric: [SeriesPoint]] = [:]
        for (i, metric) in metrics.enumerated() { result[metric] = Queries.points(buckets, rows, column: i) }
        return result
    }

    /// Shares within the `range.displayBucket` containing `time`: the top `limit` apps by value, then one
    /// `.other` share holding the stored `other` row plus every app past the limit. Fractions sum to 1.
    /// Empty when the bucket has no data or the metric totals 0.
    public func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] {
        let level = Level.coarser(Level.forRange(range), level(forIntervalStart: time))
        let width = Buckets.width(requested: range.displayBucket.milliseconds, resolution: level.resolutionMs)
        let start = Buckets.floorDiv(time.unixMs, width) * width
        let window = Window(from: start, to: start + width)
        let totals = try await writer.read { db in
            try Queries.appTotals(db, metric: metric.rawValue, level: level, window: window)
        }
        let positive = totals.filter { $0.average > 0 }
        let sum = positive.reduce(0) { $0 + $1.average }
        guard sum > 0 else { return [] }

        let ranked = positive.filter { $0.identity.key != .other }
            .sorted { ($0.average, $1.identity.key.description) > ($1.average, $0.identity.key.description) }
        let head = ranked.prefix(max(limit, 0))
        let storedOther = positive.first { $0.identity.key == .other }
        let otherValue = (storedOther?.average ?? 0) + ranked.dropFirst(head.count).reduce(0) { $0 + $1.average }

        var shares = head.map { AppShare(identity: $0.identity, value: $0.average, fraction: $0.average / sum) }
        if otherValue > 0 {
            var identity = storedOther?.identity ?? AppIdentity(key: .other, displayName: "Other")
            if identity.displayName.isEmpty { identity.displayName = "Other" }
            shares.append(AppShare(identity: identity, value: otherValue, fraction: otherValue / sum))
        }
        return shares
    }

    /// Apps (not `.other`) ranked by average over `interval` (absent samples = 0). `peak` is the highest stored
    /// value (bucket average on rollup levels); `total` = ∫ value dt in value·seconds, nil for memory.
    public func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] {
        let level = level(forIntervalStart: interval.start)
        let window = Window(from: interval.start.unixMs, to: interval.end.unixMs)
        let totals = try await writer.read { db in
            try Queries.appTotals(db, metric: metric.rawValue, level: level, window: window)
        }
        return totals.filter { $0.identity.key != .other }
            .sorted { ($0.average, $1.identity.key.description) > ($1.average, $0.identity.key.description) }
            .prefix(max(limit, 0))
            .map { AppAggregate(identity: $0.identity, average: $0.average, peak: $0.peak,
                                total: metric == .memory ? nil : $0.integral) }
    }

    /// ∫ value dt over `interval` (value·seconds, e.g. bytes for B/s, joules for W); nil without data.
    public func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? {
        try await systemAggregate(metric, interval).integral
    }

    /// Highest stored value in `interval` (bucket average on rollup levels); nil without data.
    public func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? {
        try await systemAggregate(metric, interval).peak
    }

    private func systemAggregate(_ metric: HistoryMetric, _ interval: DateInterval) async throws
        -> (integral: Double?, peak: Double?) {
        let level = level(forIntervalStart: interval.start)
        let window = Window(from: interval.start.unixMs, to: interval.end.unixMs)
        return try await writer.read { db in
            try Queries.systemAggregate(db, metric: metric.rawValue, level: level, window: window)
        }
    }

    /// Finest level that still holds `start` under retention.
    func level(forIntervalStart start: Date) -> Level {
        let age = config.now().timeIntervalSince(start)
        if age <= config.rawRetention.timeInterval { return .raw }
        if age <= config.minuteRetention.timeInterval { return .minute }
        return .quarter
    }

    public func events(in interval: DateInterval) async throws -> [HistoryEvent] {
        let window = Window(from: interval.start.unixMs, to: interval.end.unixMs)
        return try await writer.read { db in try Queries.events(db, window: window) }
    }

    public func coverage() async throws -> DateInterval? {
        try await writer.read { db in try Queries.coverage(db) }
    }

    /// Rows of `range`'s storage level in [end − duration, end); see `CSVExporter`.
    public func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        let level = level(for: range, end: end)
        let window = Window(from: end.unixMs - range.span.milliseconds, to: end.unixMs)
        return try await writer.read { db in try CSVExporter.export(db, level: level, window: window, to: url) }
    }
}
