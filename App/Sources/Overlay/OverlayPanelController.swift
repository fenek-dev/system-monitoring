import AppKit
import MonitorScreens
import os
import SwiftUI

/// Never key or main: the overlay takes no input.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// `OverlayView` with the opacity followed live from `SettingsStore` (no re-layout needed: the size is fixed).
private struct OverlayRoot: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        OverlayView(opacity: settings.overlayOpacity)
    }
}

/// On-screen stats overlay (spec 2026-09-25 overlay, "Window"): a borderless, click-through, non-activating
/// `NSPanel` at status-bar level on every Space and over full-screen apps. It sits in `settings.overlayCorner` of
/// the display under the mouse, re-evaluated on each live update and on screen-parameter changes; it moves only
/// when the frame changes. The hosting view exists only while shown.
@MainActor
final class OverlayPanelController {
    private let env: AppEnvironment
    private let onVisibilityChange: @MainActor (Bool) -> Void
    private var panel: OverlayPanel?
    private var host: NSHostingView<AnyView>?
    private var placeLoop: ObservationLoop<PlaceKey>?
    private var screenObserver: NSObjectProtocol?
    private static let log = Logger(subsystem: "dev.telltale", category: "Overlay")

    private struct PlaceKey: Equatable {
        var lastUpdate: Date?
        var corner: OverlayCorner
    }

    init(env: AppEnvironment, onVisibilityChange: @escaping @MainActor (Bool) -> Void) {
        self.env = env
        self.onVisibilityChange = onVisibilityChange
    }

    var isShown: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        // Visibility first: `live.presentation` = `.overlay` publishes the latest totals before the view reads them.
        onVisibilityChange(true)
        let host = NSHostingView(rootView: AnyView(OverlayRoot().telltaleEnvironment(env.context())))
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Stats overlay")
        panel.contentView = host
        self.panel = panel
        self.host = host
        place()
        panel.orderFrontRegardless()

        let live = env.live
        let settings = env.settings
        placeLoop = ObservationLoop({ PlaceKey(lastUpdate: live.lastUpdate, corner: settings.overlayCorner) }) {
            [weak self] _ in self?.place()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        Self.log.notice("shown frame=\(String(describing: panel.frame), privacy: .public)")
    }

    func hide() {
        guard let panel else { return }
        placeLoop?.cancel()
        placeLoop = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        host = nil
        onVisibilityChange(false)
        Self.log.notice("hidden")
    }

    /// Fitting size of the content, in the configured corner of the display under the mouse (else the main one).
    private func place() {
        guard let panel, let host else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let mainIndex = NSScreen.main.flatMap { m in screens.firstIndex { $0 == m } } ?? 0
        let i = OverlayPlacement.screenIndex(mouse: NSEvent.mouseLocation, screenFrames: screens.map(\.frame),
                                             mainIndex: mainIndex)
        let frame = OverlayPlacement.frame(size: host.fittingSize, visibleFrame: screens[i].visibleFrame,
                                           corner: env.settings.overlayCorner)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}
