import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// Shared helpers for every screen test suite (W4 owns; W5 streams use them).
///
///     let ctx = ScreenFixture.context(.calm, page: .cpu)          // deterministic ShellContext
///     assertScreen("cpu", scenario: .calm)                          // ScreenCatalog entry → golden "cpu-calm"
///     assertSnapshot(MyCard().screenEnvironment(.calm), size: ScreenSize.card, named: "cpu-cluster-calm")
@MainActor
enum ScreenFixture {
    /// `LiveModel.mock(scenario)` (frames 0…60, presenting).
    static func live(_ scenario: MockScenario, ticks: Int = 60) -> LiveModel { .mock(scenario, ticks: ticks) }

    /// Full deterministic environment (ARCHITECTURE §8): mock live/history/actions, default settings on a scratch
    /// suite, `isSnapshot`, `now = MockDataProvider.referenceDate`, en_US, Europe/London, dark.
    static func context(_ scenario: MockScenario, page: DashboardPage = .overview, ticks: Int = 60) -> ShellContext {
        ScreenCatalog.context(for: scenario, page: page, ticks: ticks)
    }

    /// Fresh settings on in-memory defaults (tests that mutate settings; no plist, no cross-process races).
    /// A second `SettingsStore(defaults: d)` over the returned defaults models a relaunch.
    static func settings() -> (SettingsStore, UserDefaults) {
        let d = InMemoryDefaults()
        return (SettingsStore(defaults: d), d)
    }

    /// True once W3's `SnapshotRenderer` produces images (the W0b stub returns nil). Gate snapshot tests with
    /// `.enabled { await ScreenFixture.snapshotsAvailable }` so they skip, not fail, before W3 lands.
    static var snapshotsAvailable: Bool {
        SnapshotRenderer.render(Color.black, size: CGSize(width: 4, height: 4)) != nil
    }
}

/// Artboard / component sizes (pt; renders are @2x).
enum ScreenSize {
    static let dashboard = ScreenCatalog.dashboardSize            // 1280×860
    static let popoverArtboard = ScreenCatalog.popoverArtboardSize // 440×720
    static let statusIcons = ScreenCatalog.statusIconsSize        // 640×330
    static let settings = ScreenCatalog.settingsSize
    /// Dashboard content area at the default size: 1280 − 220 sidebar, 860 − 53 header (52 band + 1 edge).
    static let pageContent = CGSize(width: 1060, height: 807)
    static let sidebar = CGSize(width: 220, height: 860)
    static let pageHeader = CGSize(width: 1060, height: 53)
}

extension View {
    /// Wraps a view in the deterministic environment of `scenario`.
    @MainActor func screenEnvironment(_ scenario: MockScenario, page: DashboardPage = .overview) -> some View {
        telltaleEnvironment(ScreenFixture.context(scenario, page: page))
    }
}

/// Renders a `ScreenCatalog` entry and compares it with `__Snapshots__/<id>-<scenario>.png`.
@MainActor
func assertScreen(_ id: String, scenario: MockScenario? = nil, tolerance: Double = 0.005,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    guard let entry = ScreenCatalog.entry(id) else {
        Issue.record("no ScreenCatalog entry \(id)", sourceLocation: sourceLocation)
        return
    }
    let s = scenario ?? entry.defaultScenario
    assertSnapshot(entry.make(s), size: entry.size, named: "\(id)-\(s.rawValue)", tolerance: tolerance,
                   sourceLocation: sourceLocation)
}
