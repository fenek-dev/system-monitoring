import Foundation

/// Default environment value and "History unavailable" fallback: every query returns empty/nil;
/// export writes nothing and reports 0 rows.
public struct EmptyHistoryProvider: HistoryProvider {
    public init() {}

    public func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [HistoryMetric: [SeriesPoint]] { [:] }

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
