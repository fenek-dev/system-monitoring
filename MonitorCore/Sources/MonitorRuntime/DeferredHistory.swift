import Foundation
import MonitorModel
import MonitorStore

/// `HistoryProvider` over a store still opening off the MainActor (R-M4): each query awaits the open, then
/// forwards; with no store at all it answers like `EmptyHistoryProvider`.
struct DeferredHistory: HistoryProvider {
    private let opening: Task<LivePipeline.OpenedStore, Never>

    init(_ opening: Task<LivePipeline.OpenedStore, Never>) {
        self.opening = opening
    }

    private func provider() async -> any HistoryProvider {
        await opening.value.store ?? EmptyHistoryProvider()
    }

    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [HistoryMetric: [SeriesPoint]] {
        try await provider().series(metrics, range: range, end: end, bucket: bucket)
    }

    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?)
        async throws -> [AppMetric: [SeriesPoint]] {
        try await provider().appSeries(app, metrics, range: range, end: end, bucket: bucket)
    }

    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] {
        try await provider().appShares(at: time, metric: metric, range: range, limit: limit)
    }

    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] {
        try await provider().topApps(metric, in: interval, limit: limit)
    }

    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? {
        try await provider().total(metric, in: interval)
    }

    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? {
        try await provider().peak(metric, in: interval)
    }

    func events(in interval: DateInterval) async throws -> [HistoryEvent] {
        try await provider().events(in: interval)
    }

    func coverage() async throws -> DateInterval? {
        try await provider().coverage()
    }

    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        try await provider().exportCSV(range: range, end: end, to: url)
    }
}
