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
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] {
        try await base.series(metrics, range: range, end: end, bucket: bucket)
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
    @Test func calm() { assertScreen("history", scenario: .calm) }
    @Test func collecting() { assertScreen("history", scenario: .collecting) }
    @Test func sensorsUnavailable() { assertScreen("history", scenario: .sensorsUnavailable) }
    @Test func thermalFair() { assertScreen("history", scenario: .thermalFair) }

    @Test func live() {
        assertSnapshot(Self.dashboard(.calm) { $0.navigation.historyRange = .live }, size: ScreenSize.dashboard,
                       named: "history-live-calm")
    }

    /// Cursor scrubbed back to the Final Cut Pro export; 7D range.
    @Test func scrubbedWeek() {
        assertSnapshot(Self.dashboard(.calm) { ctx in
            ctx.navigation.historyRange = .week
            ctx.navigation.historyScrub = MockDataProvider.referenceDate.addingTimeInterval(-2 * 86_400 - 7_200)
        }, size: ScreenSize.dashboard, named: "history-week-scrubbed-calm")
    }

    @Test func emptyHistory() {
        assertSnapshot(Self.dashboard(.calm) { $0.history = EmptyHistoryProvider() }, size: ScreenSize.dashboard,
                       named: "history-empty")
    }

    @Test func storeError() {
        assertSnapshot(Self.dashboard(.calm) { $0.history = FailingHistoryProvider() }, size: ScreenSize.dashboard,
                       named: "history-error")
    }

    /// Thermal Fair + memory bands with legend, a paused band, and the cursor scrubbed into the thermal episode.
    @Test func bandsAndLegend() {
        let now = MockDataProvider.referenceDate
        let thermal = HistoryEvent(kind: .thermalPressure, start: now.addingTimeInterval(-3 * 3_600),
                                   end: now.addingTimeInterval(-2 * 3_600), level: .elevated,
                                   peak: Double(ThermalPressure.fair.rawValue), label: "Thermal: Fair")
        let memory = HistoryEvent(kind: .memoryPressure, start: now.addingTimeInterval(-6 * 3_600),
                                  end: now.addingTimeInterval(-5.5 * 3_600), level: .elevated, label: "Memory: Warning")
        let provider = EventsAddingProvider(base: MockDataProvider(scenario: .calm).history(), extra: [thermal, memory])
        assertSnapshot(Self.dashboard(.calm) { ctx in
            ctx.history = provider
            ctx.navigation.historyScrub = now.addingTimeInterval(-2.5 * 3_600)
        }, size: ScreenSize.dashboard, named: "history-bands-calm")
    }

    @Test func notPersistent() {
        assertSnapshot(Self.dashboard(.calm) { $0.historyPersistent = false }, size: ScreenSize.dashboard,
                       named: "history-not-persistent")
    }

    static func dashboard(_ scenario: MockScenario, configure: (inout ShellContext) -> Void) -> some View {
        var ctx = ScreenFixture.context(scenario, page: .history)
        configure(&ctx)
        return DashboardRoot()
            .frame(width: ScreenSize.dashboard.width, height: ScreenSize.dashboard.height)
            .telltaleEnvironment(ctx)
    }
}
