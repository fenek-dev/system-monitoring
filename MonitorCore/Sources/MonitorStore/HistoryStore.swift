import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.9). W2 replaces this file.

public actor HistoryStore: HistoryProvider, HistoryRecorder {
    public enum Location: Sendable { case file(URL), inMemory }
    public init(location: Location, config: StoreConfig = .init()) throws {}
    // no flushSync: termination awaits runtime.shutdown() via .terminateLater (§4)

    // HistoryProvider
    public func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] { [:] }
    public func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] { [:] }
    public func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] { [] }
    public func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { [] }
    public func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    public func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    public func events(in interval: DateInterval) async throws -> [HistoryEvent] { [] }
    public func coverage() async throws -> DateInterval? { nil }
    public func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary { ExportSummary(url: url) }

    // HistoryRecorder
    public func append(_ batch: RecordBatch) async {}
    public func flush() async throws {}
    public func maintain(now: Date) async throws {}
}

public struct StoreConfig: Sendable {
    public var flushInterval: Duration = .seconds(30), flushMaxRecords = 120
    /// Full resolution 24 h (ruling).
    public var rawRetention: Duration = .seconds(86_400)
    public var minuteRetention: Duration = .seconds(7 * 86_400)
    public var quarterRetention: Duration = .seconds(30 * 86_400)
    public var maintenanceInterval: Duration = .seconds(300)
    public var now: @Sendable () -> Date = Date.init
    public init() {}
}
