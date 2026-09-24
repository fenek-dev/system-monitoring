import CoreGraphics
import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Screen × scenario × size, rendered by `telltale-render` and the screen snapshot tests (ARCHITECTURE §8).
/// Every page is registered here from its public `init()`, so page owners (W5) never edit this file.
///
/// Ids → reference artboards: `popover`→MenuBar, `popover-alert`→MenuBarAlert (default `.thermalFair`),
/// `status-icons`→StatusIcon, `overview`→Main, `cpu` … `history` → same-named artboards, `settings` (ADDED).
public enum ScreenCatalog {
    public struct Entry: Identifiable {
        public var id: String
        /// Artboard size in pt (renders are @2x).
        public var size: CGSize
        /// Scenario used when the caller gives none (e.g. `popover-alert` → `.thermalFair`).
        public var defaultScenario: MockScenario
        public var make: @MainActor (MockScenario) -> AnyView

        public init(id: String, size: CGSize, defaultScenario: MockScenario = .calm,
                    make: @escaping @MainActor (MockScenario) -> AnyView) {
            self.id = id
            self.size = size
            self.defaultScenario = defaultScenario
            self.make = make
        }
    }

    public static let dashboardSize = CGSize(width: 1280, height: 860)
    public static let popoverArtboardSize = CGSize(width: 440, height: 720)
    public static let statusIconsSize = CGSize(width: 640, height: 330)
    public static let settingsSize = CGSize(width: 520, height: 600)

    @MainActor public static let entries: [Entry] = {
        var e: [Entry] = [
            Entry(id: "popover", size: popoverArtboardSize) { popoverStage($0) },
            Entry(id: "popover-alert", size: popoverArtboardSize, defaultScenario: .thermalFair) { popoverStage($0) },
            Entry(id: "status-icons", size: statusIconsSize) { _ in AnyView(StatusIconsBoard()) },
        ]
        e += DashboardPage.allCases.map { page in
            Entry(id: page.rawValue, size: dashboardSize) { dashboard(page, scenario: $0) }
        }
        e.append(Entry(id: "settings", size: settingsSize) { scenario in
            let ctx = context(for: scenario)
            return AnyView(SettingsView(loginItem: .preview, about: .preview)
                .frame(width: settingsSize.width, height: settingsSize.height, alignment: .top)
                .background(ShellStyle.bgWindow)
                .telltaleEnvironment(ctx))
        })
        return e
    }()

    @MainActor public static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Deterministic context for renders/snapshots (ARCHITECTURE §8): `LiveModel.mock(scenario)` (presenting),
    /// mock history/actions, default settings on a scratch suite, `isSnapshot`, `now = referenceDate`.
    @MainActor public static func context(for scenario: MockScenario, page: DashboardPage = .overview,
                                          ticks: Int = 60) -> ShellContext {
        let provider = MockDataProvider(scenario: scenario)
        let nav = NavigationModel()
        nav.page = page
        return ShellContext(live: .mock(scenario, ticks: ticks), navigation: nav, settings: snapshotSettings(),
                            history: provider.history(), processActions: provider.processActions(log: ActionLog()),
                            appCommands: .noop, isSnapshot: true, now: MockDataProvider.referenceDate)
    }

    /// Fresh default settings on a scratch suite (never the user's defaults).
    @MainActor public static func snapshotSettings() -> SettingsStore {
        let name = "dev.telltale.Telltale.snapshot"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return SettingsStore(defaults: d)
    }

    @MainActor static func dashboard(_ page: DashboardPage, scenario: MockScenario) -> AnyView {
        let ctx = context(for: scenario, page: page)
        return AnyView(DashboardRoot()
            .frame(width: dashboardSize.width, height: dashboardSize.height)
            .telltaleEnvironment(ctx))
    }

    /// The popover as the MenuBar artboard shows it: 360-pt panel at (68, 34) over the artboard backdrop.
    @MainActor static func popoverStage(_ scenario: MockScenario) -> AnyView {
        let ctx = context(for: scenario)
        return AnyView(ZStack(alignment: .topLeading) {
            ShellStyle.hex(0x121317)
            PopoverContainer { PopoverRoot() }
                .offset(x: 68, y: 34)
        }
        .frame(width: popoverArtboardSize.width, height: popoverArtboardSize.height, alignment: .topLeading)
        .telltaleEnvironment(ctx))
    }
}

/// StatusIcon artboard: calm / elevated (thermals) / critical (thermals) glyphs at 72 pt.
struct StatusIconsBoard: View {
    static let states: [(String, AlertState)] = [
        ("Calm", .calm),
        ("Elevated", AlertState.preview(.elevated)),
        ("Critical", AlertState.preview(.critical)),
    ]

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Self.states, id: \.0) { title, state in
                VStack(alignment: .leading, spacing: 12) {
                    TTStatusGlyph(state: state, size: 72, template: false)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 12).fill(ShellStyle.hex(0x1D1E22)))
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellStyle.textPrimary)
                }
            }
        }
        .padding(24)
        .frame(width: ScreenCatalog.statusIconsSize.width, height: ScreenCatalog.statusIconsSize.height,
               alignment: .top)
        .background(ShellStyle.hex(0x121317))
    }
}

public extension AlertState {
    /// A thermals-arc alert at `level` (catalog and shell previews).
    static func preview(_ level: AlertLevel, arc: IconArc = .thermals, pulseToken: Int = 0) -> AlertState {
        var arcs = AlertState.calm.arcs
        arcs[arc] = level
        return AlertState(level: level, arcs: arcs, pulseToken: pulseToken)
    }
}

public extension LiveModel {
    /// Scenario frames 0…`ticks` applied in order (the latest is `frame(at: ticks)`, ARCHITECTURE §8), then
    /// presenting, so every snapshot property is filled. `.paused` also pauses the model at the last frame.
    @MainActor static func mock(_ scenario: MockScenario, ticks: Int = 60) -> LiveModel {
        let provider = MockDataProvider(scenario: scenario)
        let model = LiveModel(device: provider.device)
        var last: SystemFrame?
        for tick in 0...max(ticks, 0) {
            let f = provider.frame(at: tick)
            model.apply(f)
            last = f
        }
        if scenario == .paused, let last { model.setPaused(true, at: last.wallTime) }
        model.isPresenting = true
        return model
    }
}
