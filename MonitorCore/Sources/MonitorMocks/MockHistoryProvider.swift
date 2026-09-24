import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.11): returns empty/nil like EmptyHistoryProvider. Wm replaces this file.

public final class MockHistoryProvider: HistoryProvider {
    public init() {}

    public func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] { [:] }
    public func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] { [:] }
    public func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] { [] }
    public func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { [] }
    public func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    public func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    public func events(in interval: DateInterval) async throws -> [HistoryEvent] { [] }
    public func coverage() async throws -> DateInterval? { nil }
    public func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary { ExportSummary(url: url) }
}
