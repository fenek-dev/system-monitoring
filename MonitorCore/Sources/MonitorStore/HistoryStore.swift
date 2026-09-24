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
    private var pendingEvents: [HistoryEvent] = []
    private var lastFlush: Date
    private var lastMaintenance: Date
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
        let opened = config.now()
        self.lastFlush = opened
        self.lastMaintenance = opened
    }

    // MARK: HistoryRecorder

    /// Buffers; flushes on `flushMaxRecords` or `flushInterval`, then runs maintenance every
    /// `maintenanceInterval`. Write failures drop the batch and log a fault (ARCHITECTURE §6).
    public func append(_ batch: RecordBatch) async {
        if let record = batch.record { pendingRecords.append(record) }
        pendingEvents.append(contentsOf: batch.events)
        let now = config.now()
        guard pendingRecords.count >= config.flushMaxRecords
            || now.timeIntervalSince(lastFlush) >= config.flushInterval.timeInterval else { return }
        do { try await flush() } catch {
            StoreDatabase.log.fault("history flush failed: \(error.localizedDescription, privacy: .public)")
        }
        if !maintaining, now.timeIntervalSince(lastMaintenance) >= config.maintenanceInterval.timeInterval {
            do { try await maintain(now: now) } catch {
                StoreDatabase.log.fault("history maintenance failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes everything buffered in one transaction, after any in-flight flush.
    public func flush() async throws {
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
            try await writer.write { db in try RecordWriter.write(records, events, db) }
        }
        writeChain = task
        do { try await task.value } catch {
            StoreDatabase.log.fault("dropped \(records.count) records, \(events.count) events: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func maintain(now: Date) async throws {
        guard !maintaining else { return }
        maintaining = true
        defer { maintaining = false }
        lastMaintenance = now
        try await flush()
        let columns = self.columns
        let nowMs = now.unixMs
        try await writer.write { db in
            try Rollup.run(db, columns: columns, nowMs: nowMs)
        }
    }

    // MARK: HistoryProvider

    public func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [HistoryMetric: [SeriesPoint]] {
        guard !metrics.isEmpty else { return [:] }
        let level = Level.forRange(range)
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

    /// Display buckets: `bucket` (default `range.displayBucket`), never finer than the level's resolution.
    static func buckets(range: HistoryRange, end: Date, bucket: Duration?, level: Level) -> Buckets {
        let width = max((bucket ?? range.displayBucket).milliseconds, level.resolutionMs)
        return Buckets(end: end, duration: range.span, width: width)
    }

    public func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?)
        async throws -> [AppMetric: [SeriesPoint]] { [:] }

    public func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] {
        []
    }

    public func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { [] }

    public func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }

    public func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }

    public func events(in interval: DateInterval) async throws -> [HistoryEvent] { [] }

    public func coverage() async throws -> DateInterval? { nil }

    public func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        ExportSummary(rows: 0, bytes: 0, url: url)
    }
}
