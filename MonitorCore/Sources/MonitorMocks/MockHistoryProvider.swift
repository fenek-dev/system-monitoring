import Foundation
import MonitorModel

/// 30 days of synthetic history (ARCHITECTURE §5.11), generated lazily per query bucket via
/// `HistorySignal` — no full-resolution arrays are ever materialized, so a query stays fast (<20 ms)
/// regardless of how far back it reaches. Matches `MonitorStore.Queries`' real semantics (W2), not just
/// its shape: buckets are epoch-aligned (`Buckets`'s `floorDiv` keys), not anchored to `end`, so a bucket's
/// start is always an exact multiple of its width; windows are half-open `[start, end)`; each bucket
/// averages several evenly-spaced interior samples, which — since every sample represents an equal slice
/// of the bucket's duration — is the same time-weighted average the store computes via `SUM(v × interval_ms)
/// / SUM(interval_ms)`; and a bucket is a gap (`nil`) only when every sample in it is unavailable (outside
/// coverage, in the future, or the seeded "paused hour"), exactly like the store's `NULL` on an all-null
/// denominator. `.collecting` reports a short coverage window instead of the usual 30 days.
public final class MockHistoryProvider: HistoryProvider {
    private let signal: HistorySignal
    private let scenario: MockScenario
    private let roster: [DemoApp]

    /// `end`: the provider's fixed "now" — the boundary beyond which there is no data. Callers may still
    /// pass an earlier `end` to `series`/`appSeries`/etc. to look at an older window.
    public init(scenario: MockScenario = .calm, seed: UInt64 = 42, end: Date = MockDataProvider.referenceDate) {
        self.scenario = scenario
        self.signal = HistorySignal(seed: seed, end: end)
        var roster = DemoApps.roster(scenario: scenario)
        if scenario == .restricted { roster += DemoApps.extraApps(count: 24, seedOffset: seed) }
        self.roster = roster
    }

    // MARK: - Series

    public func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws
        -> [HistoryMetric: [SeriesPoint]] {
        let buckets = self.buckets(range: range, end: end, bucket: bucket)
        var result: [HistoryMetric: [SeriesPoint]] = [:]
        for metric in metrics {
            let usesMax = Self.usesPeakAggregation(metric)
            result[metric] = buckets.map { b in
                SeriesPoint(time: b.start, value: aggregate(in: b, usesMax: usesMax) { self.signal.value(metric, at: $0, scenario: self.scenario) })
            }
        }
        return result
    }

    public func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?)
        async throws -> [AppMetric: [SeriesPoint]] {
        let buckets = self.buckets(range: range, end: end, bucket: bucket)
        guard let demoApp = roster.first(where: { $0.key == app }) else {
            // Unknown app (e.g. `.other`/`.system`): a consistent shape of gaps, not an error.
            return Dictionary(uniqueKeysWithValues: metrics.map { ($0, buckets.map { SeriesPoint(time: $0.start, value: nil) }) })
        }
        var result: [AppMetric: [SeriesPoint]] = [:]
        for metric in metrics {
            result[metric] = buckets.map { b in
                SeriesPoint(time: b.start, value: aggregate(in: b, usesMax: false) { self.signal.appValue(demoApp, metric, at: $0, scenario: self.scenario) })
            }
        }
        return result
    }

    /// Sorted top `limit` shares, plus an `.other` share for the remainder whenever more than `limit`
    /// apps have a positive value — otherwise `fraction` only sums to 1 when `limit >= roster.count`.
    public func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] {
        let values = roster.compactMap { app -> (DemoApp, Double)? in
            guard let v = signal.appValue(app, metric, at: time, scenario: scenario), v > 0 else { return nil }
            return (app, v)
        }
        .sorted { $0.1 > $1.1 }
        let total = values.map(\.1).reduce(0, +)
        let top = values.prefix(limit)
        var shares = top.map { app, value in
            AppShare(identity: AppIdentity(key: app.key, displayName: app.displayName, bundlePath: app.bundlePath),
                      value: value, fraction: total > 0 ? value / total : 0)
        }
        if values.count > limit {
            let shownValue = top.map(\.1).reduce(0, +)
            let otherValue = max(0, total - shownValue)
            shares.append(AppShare(identity: AppIdentity(key: .other, displayName: "Other"),
                                    value: otherValue, fraction: total > 0 ? otherValue / total : 0))
        }
        return shares
    }

    public func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] {
        let times = sampleTimes(start: interval.start, duration: interval.duration, count: 24)
        let isCumulative: Bool = switch metric { case .netRx, .netTx, .diskRead, .diskWrite: true; default: false }
        var aggregates: [AppAggregate] = []
        for app in roster {
            let values = times.compactMap { signal.appValue(app, metric, at: $0, scenario: scenario) }
            guard !values.isEmpty else { continue }
            let average = values.reduce(0, +) / Double(values.count)
            let peak = values.max() ?? average
            aggregates.append(AppAggregate(
                identity: AppIdentity(key: app.key, displayName: app.displayName, bundlePath: app.bundlePath),
                average: average, peak: peak,
                total: isCumulative ? average * interval.duration : nil
            ))
        }
        return Array(aggregates.sorted { $0.average > $1.average }.prefix(limit))
    }

    public func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? {
        let values = sampleTimes(start: interval.start, duration: interval.duration, count: 200)
            .compactMap { signal.value(metric, at: $0, scenario: scenario) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count) * interval.duration
    }

    public func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? {
        let values = sampleTimes(start: interval.start, duration: interval.duration, count: 200)
            .compactMap { signal.value(metric, at: $0, scenario: scenario) }
        return values.max()
    }

    public func events(in interval: DateInterval) async throws -> [HistoryEvent] {
        signal.events(in: interval, scenario: scenario)
    }

    public func coverage() async throws -> DateInterval? {
        signal.coverage(scenario: scenario)
    }

    public func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        let buckets = self.buckets(range: range, end: end, bucket: nil)
        var csv = "timestamp_iso8601,cpu_pct,gpu_pct,mem_pressure_pct,net_down_Bps,net_up_Bps,soc_temp_c,package_w\n"
        let formatter = ISO8601DateFormatter()
        var rows = 0
        for b in buckets {
            func avg(_ m: HistoryMetric, usesMax: Bool = false) -> String {
                guard let v = aggregate(in: b, usesMax: usesMax, { self.signal.value(m, at: $0, scenario: self.scenario) }) else { return "" }
                return String(v)
            }
            csv += "\(formatter.string(from: b.start)),\(avg(.cpuUsage)),\(avg(.gpuUsage)),\(avg(.memPressure)),"
            csv += "\(avg(.netRx)),\(avg(.netTx)),\(avg(.socTemp, usesMax: true)),\(avg(.packageWatts))\n"
            rows += 1
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return ExportSummary(rows: rows, bytes: csv.utf8.count, url: url)
    }

    // MARK: - Buckets & sampling

    /// A handful of interior samples per bucket (the underlying signal only meaningfully changes every
    /// ~5 minutes), not one per second — this is what keeps a 30-day query well under the 20 ms budget.
    private static let samplesPerBucket = 6

    /// Epoch-aligned buckets (matching `MonitorStore.Queries.Buckets`, not anchored to `end`): bucket
    /// keys are `floorDiv(startEpoch, width) ... floorDiv(endEpoch + width - 1, width) - 1`, so every
    /// bucket's start is an exact multiple of `width` seconds since the Unix epoch, and the last bucket
    /// (which may only be partially covered, since `end` need not land on a boundary) still reads only up
    /// to `end` — `HistorySignal.isAvailable` already refuses samples after `end` as "the future".
    private func buckets(range: HistoryRange, end: Date, bucket: Duration?) -> [DateInterval] {
        let width = Int64(max(1, (bucket ?? range.displayBucket).seconds.rounded()))
        let windowSeconds = Int64((range.duration ?? .seconds(86_400)).seconds.rounded())
        let endEpoch = Int64(end.timeIntervalSince1970.rounded(.down))
        let startEpoch = endEpoch - windowSeconds
        let firstKey = Self.floorDiv(startEpoch, width)
        let lastKey = Self.floorDiv(endEpoch + width - 1, width) - 1
        guard lastKey >= firstKey else { return [] }
        return (firstKey...lastKey).map { k in
            DateInterval(start: Date(timeIntervalSince1970: Double(k * width)), duration: Double(width))
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Mean for rates/%, max for temperatures (§5.10); `nil` (a gap) only when every sample is unavailable.
    private func aggregate(in bucket: DateInterval, usesMax: Bool, _ valueAt: (Date) -> Double?) -> Double? {
        let values = sampleTimes(start: bucket.start, duration: bucket.duration, count: Self.samplesPerBucket)
            .compactMap(valueAt)
        guard !values.isEmpty else { return nil }
        return usesMax ? values.max()! : values.reduce(0, +) / Double(values.count)
    }

    private func sampleTimes(start: Date, duration: TimeInterval, count: Int) -> [Date] {
        (0..<max(1, count)).map { i in start.addingTimeInterval(duration * (Double(i) + 0.5) / Double(max(1, count))) }
    }

    private static func usesPeakAggregation(_ metric: HistoryMetric) -> Bool {
        switch metric {
        case .socTemp, .cpuPTemp, .cpuETemp, .gpuTemp, .ssdTemp, .batteryTemp: true
        default: false
        }
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}
