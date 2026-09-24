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

    @Test func commandOnlyStandardShortcutIsReserved() {
        #expect(HotKeyRecorder.handle(keyCode: 8, flags: NSEvent.ModifierFlags.command.rawValue) == .reserved)
        #expect(HotKeyRecorder.handle(keyCode: 43, flags: NSEvent.ModifierFlags.command.rawValue) == .reserved)
        #expect(HotKeyRecorder.message(for: .reserved) == "Reserved by macOS")
        #expect(HotKeyRecorder.message(for: .invalid) == "Needs ⌘, ⌥ or ⌃")
        #expect(HotKeyRecorder.message(for: .cancelled) == nil)
    }

    /// Recording start/stop reaches `AppCommands.setHotKeyRecording` once per transition (S4 unregisters the
    /// global hotkey meanwhile); tearing the capture down while recording reports the stop.
    @Test func captureReportsRecordingTransitions() {
        var log: [Bool] = []
        let c = KeyCaptureCoordinator()
        c.onRecording = { log.append($0) }
        c.setActive(true)
        c.setActive(true)
        c.setActive(false)
        c.setActive(false)
        #expect(log == [true, false])
        c.setActive(true)
        c.teardown()
        #expect(log == [true, false, true, false])
    }

    /// Only key events aimed at the recorder's own window are captured.
    @Test func captureOnlyAcceptsItsOwnWindow() {
        let mine = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        mine.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        #expect(KeyCaptureCoordinator.accepts(eventWindow: mine, viewWindow: mine))
        #expect(!KeyCaptureCoordinator.accepts(eventWindow: other, viewWindow: mine))
        #expect(!KeyCaptureCoordinator.accepts(eventWindow: nil, viewWindow: mine))
        #expect(!KeyCaptureCoordinator.accepts(eventWindow: nil, viewWindow: nil))
    }

    /// The recorder's window resigning key stops recording.
    @Test func windowResigningKeyStopsRecording() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSView()
        window.contentView = view
        var stops = 0
        let c = KeyCaptureCoordinator()
        c.view = view
        c.onResignKey = { stops += 1 }
        c.setActive(true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())   // not ours
        #expect(stops == 0)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(stops == 1)
        c.setActive(false)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(stops == 1)                                           // observer removed with the monitor
    }

    @Test func popoverOverlayToggleAccessibilityValue() {
        #expect(PopoverFooter.overlayAccessibilityValue(enabled: true) == "On")
        #expect(PopoverFooter.overlayAccessibilityValue(enabled: false) == "Off")
    }

    /// A window capped below the intrinsic height (small screens) scrolls the sections instead of clipping them:
    /// the capped view reports the cap and adds one scroll view (the popover-rows List has its own).
    @Test func settingsCappedHeightScrolls() {
        SnapshotRenderer.configureTextRendering()
        func scrollViews(_ maxHeight: CGFloat?, height: CGFloat) -> (fit: CGFloat, count: Int) {
            let (settings, _) = ScreenFixture.settings()
            let ctx = ShellContext(live: LiveModel(), settings: settings, isSnapshot: true)
            let host = NSHostingView(rootView: SettingsView(loginItem: .preview, about: .preview, maxHeight: maxHeight)
                .telltaleEnvironment(ctx))
            let fit = host.fittingSize.height
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 520, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func count(_ v: NSView) -> Int { (v is NSScrollView ? 1 : 0) + v.subviews.map(count).reduce(0, +) }
            defer { window.close() }
            return (fit, count(host))
        }
        let full = scrollViews(nil, height: ScreenCatalog.settingsSize.height)
        let capped = scrollViews(700, height: 700)
        #expect(full.fit == ScreenCatalog.settingsSize.height)
        #expect(capped.fit == 700)
        #expect(capped.count == full.count + 1)
    }

    @Test func settingsShortcutStatusText() {
        #expect(SettingsView.shortcutStatusText(.unavailable) == "Shortcut unavailable — in use by another app")
        #expect(SettingsView.shortcutStatusText(.registered) == nil)
        #expect(HotKeyStatus.registered == EnvironmentValues().overlayHotKeyStatus)
        #expect(HotKeyState().status == .registered)
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
