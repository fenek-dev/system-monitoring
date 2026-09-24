import AppKit
import MonitorLive
@testable import MonitorScreens
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Hot key recorder") @MainActor
struct HotKeyRecorderTests {
    @Test func validComboIsSaved() {
        #expect(HotKeyRecorder.handle(keyCode: 6, flags: NSEvent.ModifierFlags.option.rawValue)
                == .saved(.defaultOverlay))
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        #expect(HotKeyRecorder.handle(keyCode: 31, flags: flags.rawValue)
                == .saved(HotKeySpec(keyCode: 31, modifiers: 256 | 512)))
    }

    @Test func escapeCancels() {
        #expect(HotKeyRecorder.handle(keyCode: 53, flags: 0) == .cancelled)
        #expect(HotKeyRecorder.handle(keyCode: 53, flags: NSEvent.ModifierFlags.command.rawValue) == .cancelled)
    }

    @Test func shiftOnlyOrBareKeyIsInvalid() {
        #expect(HotKeyRecorder.handle(keyCode: 6, flags: NSEvent.ModifierFlags.shift.rawValue) == .invalid)
        #expect(HotKeyRecorder.handle(keyCode: 6, flags: 0) == .invalid)
    }

    @Test func settingsShortcutStatusText() {
        #expect(SettingsView.shortcutStatusText(.unavailable) == "Shortcut unavailable — in use by another app")
        #expect(SettingsView.shortcutStatusText(.registered) == nil)
        #expect(HotKeyStatus.registered == EnvironmentValues().overlayHotKeyStatus)
    }

    /// The "⌥Z blocks typing Ω." note describes the default shortcut only.
    @Test func settingsShortcutNoteFollowsTheSpec() {
        #expect(SettingsView.shortcutNote(.defaultOverlay) == "⌥Z blocks typing Ω.")
        #expect(SettingsView.shortcutNote(HotKeySpec(keyCode: 31, modifiers: 256 | 512)) == nil)
    }

    /// `ScreenCatalog.settingsSize` is the real window's intrinsic height (the app sizes it with
    /// `sizingOptions = [.preferredContentSize]`), so the golden shows exactly what the window shows.
    @Test func settingsCatalogHeightIsIntrinsic() {
        SnapshotRenderer.configureTextRendering()        // before any text layout in this process (goldens)
        let (settings, _) = ScreenFixture.settings()
        let ctx = ShellContext(live: LiveModel(), settings: settings, isSnapshot: true)
        let host = NSHostingController(rootView: SettingsView(loginItem: .preview, about: .preview)
            .telltaleEnvironment(ctx))
        host.safeAreaRegions = []
        #expect(host.view.fittingSize == ScreenCatalog.settingsSize)
    }
}
