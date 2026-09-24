import Foundation
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import Testing

/// Shell chrome goldens (`__Snapshots__/shell-*`). Skipped until W3's `SnapshotRenderer` renders; record with
/// `TELLTALE_RECORD=1 scripts/test.sh ShellSnapshotTests` after the visual check against Main/MenuBar/StatusIcon.
@Suite("Shell snapshots (ShellSnapshotTests)", .enabled { await ScreenFixture.snapshotsAvailable }) @MainActor
struct ShellSnapshotTests {
    @Test func overviewChromeCalm() { assertScreen("overview", scenario: .calm) }
    @Test func overviewChromePaused() { assertScreen("overview", scenario: .paused) }
    @Test func statusIcons() { assertScreen("status-icons") }
    @Test func settings() { assertScreen("settings") }
    @Test func popoverStageCalm() { assertScreen("popover", scenario: .calm) }
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
