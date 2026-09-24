import Foundation
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import SwiftUI
import Testing

/// Shell chrome goldens, all named `shell-*` (W4's snapshot namespace). Chrome only: sidebar and page header are
/// rendered without a page, so W5 page changes never touch these; full screens (`overview`, `popover`…) are the
/// page owners' goldens. Skipped until W3's `SnapshotRenderer` renders. Record with
/// `TELLTALE_RECORD=1 scripts/test.sh ShellSnapshotTests` after the visual check against Main/StatusIcon.
@Suite("Shell snapshots (ShellSnapshotTests)") @MainActor
struct ShellSnapshotTests {
    /// Calm only: DESIGN §3.15 "Paused" changes charts, the popover status, the Overview subtitle and the pause
    /// glyphs, not the sidebar (it keeps the last values), so a paused sidebar golden would duplicate this one.
    /// Paused is covered by `shell-header-overview-paused`.
    @Test func sidebar() {
        assertSnapshot(Sidebar().frame(height: ScreenSize.sidebar.height).screenEnvironment(.calm),
                       size: ScreenSize.sidebar, named: "shell-sidebar-calm")
    }

    @Test(arguments: [DashboardPage.overview, .processes, .history])
    func pageHeader(_ page: DashboardPage) {
        assertSnapshot(PageHeader().frame(width: ScreenSize.pageHeader.width).screenEnvironment(.calm, page: page),
                       size: ScreenSize.pageHeader, named: "shell-header-\(page.rawValue)-calm")
    }

    @Test func pageHeaderPaused() {
        assertSnapshot(PageHeader().frame(width: ScreenSize.pageHeader.width).screenEnvironment(.paused),
                       size: ScreenSize.pageHeader, named: "shell-header-overview-paused")
    }

    @Test func statusIcons() {
        assertSnapshot(ScreenCatalog.entry("status-icons")!.make(.calm), size: ScreenSize.statusIcons,
                       named: "shell-status-icons")
    }

    @Test func settings() {
        assertSnapshot(ScreenCatalog.entry("settings")!.make(.calm), size: ScreenSize.settings, named: "shell-settings")
    }

    /// Overlay section when the App could not register the shortcut ("Shortcut unavailable — …" in elevated).
    @Test func settingsHotKeyUnavailable() {
        let size = CGSize(width: ScreenSize.settings.width, height: ScreenSize.settings.height + 40)
        assertSnapshot(SettingsView(loginItem: .preview, about: .preview)
                        .environment(\.overlayHotKeyStatus, .unavailable)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .background(ShellStyle.bgWindow)
                        .telltaleEnvironment(ScreenFixture.context(.calm)),
                       size: size, named: "shell-settings-hotkey-unavailable")
    }
}

/// `TELLTALE_SHELL_RENDER=1 scripts/test.sh ShellRenderTests` writes `.build/renders/shell-<id>-<scenario>.png`
/// with the offscreen fallback renderer (visual check only; no comparison).
@Suite("Shell renders (manual)", .enabled(if: ProcessInfo.processInfo.environment["TELLTALE_SHELL_RENDER"] != nil))
@MainActor
struct ShellRenderTests {
    @Test(arguments: ["overview", "status-icons", "popover", "popover-alert", "settings"])
    func render(_ id: String) throws {
        let e = try #require(ScreenCatalog.entry(id))
        let url = ShellOffscreenRender.outputDirectory
            .appendingPathComponent("shell-\(id)-\(e.defaultScenario.rawValue).png")
        try ShellOffscreenRender.png(e.make(e.defaultScenario), size: e.size, to: url)
    }
}
