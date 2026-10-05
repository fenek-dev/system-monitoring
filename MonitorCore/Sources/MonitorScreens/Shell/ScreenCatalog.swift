import ClipboardCore
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
/// `status-icons`→StatusIcon, `overview`→Main, `cpu` … `history` → same-named artboards, `settings` (ADDED),
/// `clipboard`, `clipboard-search|empty|nomatch|banner` (ADDED, DESIGN §3.18: no artboard).
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
    public static let settingsSize = CGSize(width: 520, height: 1040)      // intrinsic height of the real window
    public static let clipboardArtboardSize = CGSize(width: 460, height: 500)

    @MainActor public static let entries: [Entry] = {
        var e: [Entry] = [
            Entry(id: "popover", size: popoverArtboardSize) { popoverStage($0) },
            Entry(id: "popover-alert", size: popoverArtboardSize, defaultScenario: .thermalFair) { popoverStage($0) },
            Entry(id: "status-icons", size: statusIconsSize) { _ in AnyView(StatusIconsBoard()) },
        ]
        e += DashboardPage.allCases.map { page in
            Entry(id: page.rawValue, size: dashboardSize) { dashboard(page, scenario: $0) }
        }
        // Each state is built synchronously (renders can't await), so models are seeded rather than loaded.
        for kind in MockStorageState.Kind.allCases where kind != .empty {
            let name = "storage-" + kind.rawValue.lowercased()
            for (suffix, size) in [("", dashboardSize), ("-1100", ShellStyle.dashboardMinSize)] {
                e.append(Entry(id: name + suffix, size: size) {
                    dashboard(.storage, scenario: $0, size: size, storage: kind)
                })
            }
        }
        e.append(Entry(id: "storage-1100", size: ShellStyle.dashboardMinSize) {
            dashboard(.storage, scenario: $0, size: ShellStyle.dashboardMinSize)
        })
        e.append(Entry(id: "settings", size: settingsSize) { scenario in
            let ctx = context(for: scenario)
            return AnyView(SettingsView(loginItem: .preview, about: .preview)
                .frame(width: settingsSize.width, height: settingsSize.height, alignment: .top)
                .background(ShellStyle.bgWindow)
                .telltaleEnvironment(ctx))
        })
        let history = ClipboardFixture.items(now: MockDataProvider.referenceDate)
        for (id, items, query, banner) in [("clipboard", history, "", false),
                                           ("clipboard-search", history, "saf", false),
                                           ("clipboard-empty", [], "", false),
                                           ("clipboard-nomatch", history, "zzq", false),
                                           ("clipboard-banner", history, "", true)] {
            e.append(Entry(id: id, size: clipboardArtboardSize) { _ in
                clipboardStage(items: items, query: query, needsAccessibility: banner)
            })
        }
        return e
    }()

    @MainActor public static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Deterministic context for renders/snapshots (ARCHITECTURE §8): `LiveModel.mock(scenario)` (presenting),
    /// mock history/actions, default settings on a scratch suite, `isSnapshot`, `now = referenceDate`.
    @MainActor public static func context(for scenario: MockScenario, page: DashboardPage = .overview,
                                          ticks: Int = 60, storage: StorageModel? = nil) -> ShellContext {
        let provider = MockDataProvider(scenario: scenario)
        let nav = NavigationModel()
        nav.page = page
        return ShellContext(live: .mock(scenario, ticks: ticks), navigation: nav, settings: snapshotSettings(),
                            history: provider.history(), processActions: provider.processActions(log: ActionLog()),
                            appCommands: .noop, isSnapshot: true, now: MockDataProvider.referenceDate,
                            storage: storage ?? storageModel(.empty))
    }

    /// A Storage model in the given mock state, built synchronously (`.task` never runs in `SnapshotRenderer`).
    @MainActor public static func storageModel(_ kind: MockStorageState.Kind) -> StorageModel {
        let state = MockStorageState.make(kind)
        var actions = MockDataProvider(scenario: .calm).storageActions(log: ActionLog(), state: state)
        if kind == .scanning {
            // Never yields, so the seeded in-progress state is all the render shows.
            actions.scan = { _, _ in AsyncStream { _ in } }
        }
        let model = StorageModel(actions: actions, home: MockStorageState.home,
                                 now: { MockDataProvider.referenceDate })
        model.seedAccess(hasFullDiskAccess: state.hasFullDiskAccess, availableRoots: [.home(MockStorageState.home)])
        switch kind {
        case .empty:
            break
        case .scanning:
            model.startScan()
            if let progress = state.progress { model.apply(.progress(progress)) }
            if let tree = state.tree { model.apply(.partial(tree)) }
        case .map, .cleanup, .noFDA:
            if let tree = state.tree, let overlay = state.overlay, let set = state.cleanup {
                model.adopt(tree: tree, overlay: overlay, cleanup: set)
            }
        }
        return model
    }

    /// Fresh default settings held in memory only (`InMemoryDefaults`): no plist, nothing shared between
    /// concurrent test processes or worktrees, nothing left behind.
    @MainActor public static func snapshotSettings() -> SettingsStore {
        SettingsStore(defaults: InMemoryDefaults())
    }

    @MainActor static func dashboard(_ page: DashboardPage, scenario: MockScenario,
                                     size: CGSize = dashboardSize,
                                     storage: MockStorageState.Kind? = nil) -> AnyView {
        let ctx = context(for: scenario, page: page, storage: storage.map(storageModel))
        return AnyView(DashboardRoot()
            .environment(\.storageInitialMode, storage == .cleanup ? .cleanup : .spaceMap)
            .frame(width: size.width, height: size.height)
            .telltaleEnvironment(ctx))
    }

    /// The clipboard picker (DESIGN §3.18) on the fake desktop, 20 pt of it visible around the panel.
    @MainActor static func clipboardStage(items: [ClipItem], query: String, needsAccessibility: Bool) -> AnyView {
        let model = ClipboardPickerModel(items: items, now: MockDataProvider.referenceDate,
                                         needsAccessibility: needsAccessibility)
        model.query = query
        return AnyView(ClipboardPickerView(model: model)
            .frame(width: clipboardArtboardSize.width, height: clipboardArtboardSize.height)
            .background(ShellStyle.hex(0x121317)))
    }

    /// The MenuBar/MenuBarAlert artboard (440×720): desktop `#121317`, 26-pt fake menu bar with the highlighted
    /// status item (16-pt glyph) and the clock, and the 360-pt panel at (68, 34).
    @MainActor static func popoverStage(_ scenario: MockScenario) -> AnyView {
        let ctx = context(for: scenario)
        return AnyView(ZStack(alignment: .topLeading) {
            ShellStyle.hex(0x121317)
            ArtboardMenuBar(alert: ctx.live.alert)
            PopoverContainer { PopoverRoot() }
                .offset(x: 68, y: 34)
        }
        .frame(width: popoverArtboardSize.width, height: popoverArtboardSize.height, alignment: .topLeading)
        .telltaleEnvironment(ctx))
    }
}

/// Artboard-only fake menu bar (DESIGN §1.1 "Artboard-only values": `rgba(28,28,32,0.92)`), 26 pt.
struct ArtboardMenuBar: View {
    let alert: AlertState

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            Color.clear.frame(width: 16, height: 16)                // (keeps its size while W3's glyph is a stub)
                .overlay(TTStatusGlyph(state: alert, size: 16, template: false))
                .padding(.horizontal, 5)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.2)))
            Text("Thu 24 Sep 2:32 PM")
                .font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(ShellStyle.textPrimary)
                .padding(.leading, 14)
                .padding(.trailing, 12)
        }
        .frame(width: ScreenCatalog.popoverArtboardSize.width, height: 26)
        .background(ShellStyle.hex(0x1A1A1D))   // rgba(28,28,32,0.92) over the artboard desktop, flattened
    }
}

/// StatusIcon artboard (640×330): three cards (72-pt glyph on `#1D1E22`, 1-pt border), each with a menu-bar
/// strip (16-pt glyph + "2:32 PM"), a title and the §3.3 caption.
struct StatusIconsBoard: View {
    static let states: [(title: String, state: AlertState, caption: String)] = [
        ("Calm", .calm,
         "Monochrome, follows the menu bar tint. Five arcs: CPU, GPU, memory, network, thermals."),
        ("Elevated", AlertState.preview(.elevated),
         "The stressed category’s arc and the center turn amber. Here, thermals is at Fair."),
        ("Critical", AlertState.preview(.critical),
         "Arc and center turn red and the icon pulses once. It stays red until the stress clears."),
    ]

    private static let cardFill = ShellStyle.hex(0x1D1E22)

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Self.states, id: \.title) { item in
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        card(12)
                        TTStatusGlyph(state: item.state, size: 72, template: false)
                    }
                    .frame(height: 122)
                    // Artboard strip: gap 10, padding 0 10, 12-px time label.
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Color.clear.frame(width: 16, height: 16)
                            .overlay(TTStatusGlyph(state: item.state, size: 16, template: false))
                        Text("2:32 PM")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(ShellStyle.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(card(8))
                    .padding(.top, 12)
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellStyle.textPrimary)
                        .padding(.top, 11)
                    Text(item.caption)
                        .font(.system(size: 12)).lineSpacing(4)                  // body12Para
                        .foregroundStyle(ShellStyle.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                .frame(width: 184)
            }
        }
        .padding(24)
        .frame(width: ScreenCatalog.statusIconsSize.width, height: ScreenCatalog.statusIconsSize.height,
               alignment: .topLeading)
        .background(ShellStyle.hex(0x121317))
    }

    private func card(_ r: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(Self.cardFill)
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(ShellStyle.borderCard, lineWidth: 1))
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
    /// Scenario frames 0…`ticks` (only frame 0 for `.collecting`) applied in order (the latest is `frame(at: ticks)`,
    /// ARCHITECTURE §8), then
    /// presenting at `presentation` (`.full`: every snapshot property is filled; `.overlay`: only what the overlay
    /// reads). `.paused` also pauses the model at the last frame.
    @MainActor static func mock(_ scenario: MockScenario, ticks: Int = 60,
                                presentation: LivePresentation = .full) -> LiveModel {
        let provider = MockDataProvider(scenario: scenario)
        let model = LiveModel(device: provider.device)
        var last: SystemFrame?
        // `.collecting` = DESIGN §3.15 "First launch": one sample only, so charts are below the 2-sample threshold
        // and show "Collecting…".
        let lastTick = scenario == .collecting ? 0 : max(ticks, 0)
        for tick in 0...lastTick {
            let f = provider.frame(at: tick)
            model.apply(f)
            last = f
        }
        if scenario == .paused, let last { model.setPaused(true, at: last.wallTime) }
        model.presentation = presentation
        return model
    }
}
