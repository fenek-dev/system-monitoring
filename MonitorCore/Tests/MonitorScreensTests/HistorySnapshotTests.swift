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
