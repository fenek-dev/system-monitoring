import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// Provider whose every query fails (DESIGN §3.15 "Store error").
struct FailingHistoryProvider: HistoryProvider {
    struct Failure: Error, CustomStringConvertible { var description: String { "database disk image is malformed" } }
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] { throw Failure() }
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] { throw Failure() }
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] { throw Failure() }
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { throw Failure() }
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { throw Failure() }
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { throw Failure() }
    func events(in interval: DateInterval) async throws -> [HistoryEvent] { throw Failure() }
    func coverage() async throws -> DateInterval? { throw Failure() }
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary { throw Failure() }
}

/// The mock's history plus extra events (bands/legend coverage: the mock has no pressure episodes).
struct EventsAddingProvider: HistoryProvider {
    let base: MockHistoryProvider
    let extra: [HistoryEvent]
    /// ICR-12 `memPressureLevel` overrides: (interval, level).
    var memoryLevels: [(DateInterval, Double)] = []
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] {
        var out = try await base.series(metrics, range: range, end: end, bucket: bucket)
        if let pts = out[.memPressureLevel], !memoryLevels.isEmpty {
            out[.memPressureLevel] = pts.map { p in
                guard let hit = memoryLevels.first(where: { $0.0.contains(p.time) }) else { return p }
                return SeriesPoint(time: p.time, value: hit.1)
            }
        }
        return out
    }
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] {
        try await base.appSeries(app, metrics, range: range, end: end, bucket: bucket)
    }
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] {
        try await base.appShares(at: time, metric: metric, range: range, limit: limit)
    }
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] {
        try await base.topApps(metric, in: interval, limit: limit)
    }
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { try await base.total(metric, in: interval) }
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { try await base.peak(metric, in: interval) }
    func events(in interval: DateInterval) async throws -> [HistoryEvent] {
        try await base.events(in: interval) + extra.filter { interval.contains($0.start) }
    }
    func coverage() async throws -> DateInterval? { try await base.coverage() }
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        try await base.exportCSV(range: range, end: end, to: url)
    }
}

@Suite("History snapshots")
@MainActor
struct HistorySnapshotTests {
    @Test func calm() async { await Self.check("history-calm", .calm) }
    @Test func collecting() async { await Self.check("history-collecting", .collecting) }
    @Test func sensorsUnavailable() async { await Self.check("history-sensorsUnavailable", .sensorsUnavailable) }
    @Test func thermalFair() async { await Self.check("history-thermalFair", .thermalFair) }

    @Test func live() async {
        await Self.check("history-live-calm", .calm) { $0.navigation.historyRange = .live }
    }

    /// 7D with the cursor scrubbed back two days (axis day starts, chips, "At" time).
    @Test func scrubbedWeek() async {
        await Self.check("history-week-scrubbed-calm", .calm, scrub: -2 * 86_400 - 7_200) {
            $0.navigation.historyRange = .week
        }
    }

    @Test func month() async {
        await Self.check("history-month-calm", .calm) { $0.navigation.historyRange = .month }
    }

    @Test func emptyHistory() async {
        await Self.check("history-empty", .calm) { $0.history = EmptyHistoryProvider() }
    }

    @Test func storeError() async {
        await Self.check("history-error", .calm) { $0.history = FailingHistoryProvider() }
    }

    /// Thermal Fair + memory (critical: red) bands with legend; cursor in the thermal episode (SoC note).
    @Test func bandsAndLegend() async {
        let now = MockDataProvider.referenceDate
        let thermal = HistoryEvent(kind: .thermalPressure, start: now.addingTimeInterval(-3 * 3_600),
                                   end: now.addingTimeInterval(-2 * 3_600), level: .elevated,
                                   peak: Double(ThermalPressure.fair.rawValue), label: "Thermal: Fair")
        let memory = HistoryEvent(kind: .memoryPressure, start: now.addingTimeInterval(-6 * 3_600),
                                  end: now.addingTimeInterval(-5.5 * 3_600), level: .critical, label: "Memory: Critical")
        let provider = EventsAddingProvider(
            base: MockDataProvider(scenario: .calm).history(), extra: [thermal, memory],
            memoryLevels: [(DateInterval(start: now.addingTimeInterval(-6 * 3_600), duration: 1_800), 4),
                           (DateInterval(start: now.addingTimeInterval(-5.5 * 3_600), duration: 1_800), 2)])
        await Self.check("history-bands-calm", .calm, scrub: -2.5 * 3_600) { $0.history = provider }
    }

    /// Store could not be opened: banner over the working (in-memory) history (ruling b).
    @Test func notPersistent() async {
        await Self.check("history-not-persistent", .calm) { $0.historyPersistent = false }
    }

    /// Renders the dashboard on History with a model pre-loaded from the context's provider (snapshots have no
    /// run-loop wait for async loads). `scrub`: seconds from the reference date for the cursor.
    static func check(_ name: String, _ scenario: MockScenario, scrub: TimeInterval? = nil,
                      sourceLocation: SourceLocation = #_sourceLocation,
                      configure: (inout ShellContext) -> Void = { _ in }) async {
        var ctx = ScreenFixture.context(scenario, page: .history)
        configure(&ctx)
        let range = ctx.navigation.historyRange
        var seed: HistoryModel?
        if range != .live {
            let now = ctx.now ?? MockDataProvider.referenceDate
            let m = HistoryModel(range: range, now: now, provider: ctx.history, calendar: HT.london)
            m.select(range, now: now, restoring: scrub.map { now.addingTimeInterval($0) })
            await m.load()
            seed = m
        }
        let view = DashboardRoot()
            .environment(\.historyModelSeed, seed)
            .frame(width: ScreenSize.dashboard.width, height: ScreenSize.dashboard.height)
            .telltaleEnvironment(ctx)
        assertSnapshot(view, size: ScreenSize.dashboard, named: name, sourceLocation: sourceLocation)
    }
}
