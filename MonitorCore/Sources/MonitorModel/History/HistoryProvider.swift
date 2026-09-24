import Foundation

public protocol HistoryProvider: Sendable {
    /// Bucketed to `bucket` (default range.displayBucket, AVG); gap points (value nil) where a bucket has no rows.
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [HistoryMetric: [SeriesPoint]]
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [AppMetric: [SeriesPoint]]
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare]
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate]
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double?
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double?
    func events(in interval: DateInterval) async throws -> [HistoryEvent]
    func coverage() async throws -> DateInterval?
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary
}

/// Protocol requirements can't have default arguments; these overloads pass bucket: nil (= range.displayBucket).
public extension HistoryProvider {
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date) async throws
        -> [HistoryMetric: [SeriesPoint]] {
        try await series(metrics, range: range, end: end, bucket: nil)
    }

    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date) async throws
        -> [AppMetric: [SeriesPoint]] {
        try await appSeries(app, metrics, range: range, end: end, bucket: nil)
    }
}

public protocol HistoryRecorder: Sendable {
    func append(_ batch: RecordBatch) async
    func flush() async throws
    func maintain(now: Date) async throws
}
