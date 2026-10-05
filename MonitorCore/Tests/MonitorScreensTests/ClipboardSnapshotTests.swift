import MonitorMocks
@testable import MonitorScreens
import MonitorSnapshotTesting
import Testing

/// Clipboard picker goldens (`__Snapshots__/<id>-calm.png`) from the `ScreenCatalog` entries, dark.
@Suite("ClipboardSnapshotTests") @MainActor
struct ClipboardSnapshotTests {
    @Test(arguments: ["clipboard", "clipboard-search", "clipboard-empty", "clipboard-nomatch", "clipboard-banner"])
    func picker(_ id: String) {
        ScreenFixture.prepareTextRendering()
        assertScreen(id)
    }
}
