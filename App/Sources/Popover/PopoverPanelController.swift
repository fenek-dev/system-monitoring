import AppKit
import os
import MonitorScreens
import SwiftUI

/// Borderless panel that can take key status (Esc, ⌘ shortcuts) without activating the app.
final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Menu bar popover (DESIGN §3.1, ARCHITECTURE §5.13): borderless non-activating `NSPanel`, 360 pt, under the
/// status item. Closes on outside click, Esc, or a second status click. The hosting controller is created on
/// open and released on close, so the SwiftUI tree (and its observation) only exists while visible.
@MainActor
final class PopoverPanelController: NSObject {
    private let env: AppEnvironment
    private let anchor: @MainActor () -> NSRect?
    private let onVisibilityChange: @MainActor (Bool) -> Void
    private let shortcuts: @MainActor (NSEvent) -> Bool

    private var panel: PopoverPanel?
    private var host: NSHostingController<AnyView>?
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var lastClose: ContinuousClock.Instant?

    /// `shortcuts` handles ⌘Q/⌘,/⌘D while the panel is key (the app is not active, so the main menu does not
    /// see them); return true when consumed.
    init(env: AppEnvironment, anchor: @escaping @MainActor () -> NSRect?,
         onVisibilityChange: @escaping @MainActor (Bool) -> Void,
         shortcuts: @escaping @MainActor (NSEvent) -> Bool) {
        self.env = env
        self.anchor = anchor
        self.onVisibilityChange = onVisibilityChange
        self.shortcuts = shortcuts
    }

    var isOpen: Bool { panel != nil }

    /// Status click. A close within the last 250 ms came from the same click (resign-key or a monitor saw the
    /// mouse-down first), so it must not reopen.
    func toggle() {
        if isOpen { return close() }
        if let t = lastClose, ContinuousClock.now - t < .milliseconds(250) { return }
        open()
    }

    func open() {
        guard panel == nil else { return }
        // Visibility first: `live.isPresenting` must apply the latest frame before the view tree reads it.
        onVisibilityChange(true)
        let root = PopoverContainer(drawsShadow: false) { PopoverRoot() }
            .telltaleEnvironment(env.context())
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = [.preferredContentSize]

        let panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 478),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = host
        panel.setAccessibilityLabel("Telltale")

        self.panel = panel
        self.host = host
        place()
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.place() }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        // Cmd-Tab / another app activating / one of our windows becoming key → close.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let nc = NotificationCenter.default
        placementObservers = [
            nc.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclamp() }
            },
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                           queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
        ]
        // First layout pass can finish after this run-loop turn: place once more with the final size.
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private var placementObservers: [NSObjectProtocol] = []

    func close() {
        guard let panel else { return }
        removeMonitors()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        placementObservers.forEach(NotificationCenter.default.removeObserver)
        placementObservers.removeAll()
        sizeObservation = nil
        panel.close()
        panel.contentViewController = nil
        self.panel = nil
        host = nil
        lastClose = .now
        onVisibilityChange(false)
    }

    /// Size from the laid-out SwiftUI content (never an assumed 360), then `PopoverPlacement` against the visible
    /// frame of the status item's own screen.
    private func place() {
        guard let panel, let host else { return }
        host.view.layoutSubtreeIfNeeded()
        var size = host.view.fittingSize
        if size.width < 1 || size.height < 1 { size = host.preferredContentSize }
        if size.width < 1 { size.width = 360 }
        let (a, screen) = anchorAndScreen()
        guard let screen else { return }
        // No usable anchor (item hidden behind the notch, or not yet placed at launch): center on the screen.
        let anchorRect = a ?? NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)
        let f = PopoverPlacement.frame(anchor: anchorRect, content: size, visibleFrame: screen.visibleFrame)
        placing = true
        panel.setFrame(f, display: true)
        placing = false
        reclamp()
        Self.log.debug("""
            place anchor=\(String(describing: a), privacy: .public) visible=\(String(describing: screen.visibleFrame), privacy: .public) \
            size=\(String(describing: size), privacy: .public) → \(String(describing: panel.frame), privacy: .public)
            """)
    }

    /// AppKit may resize the panel to the hosting controller's preferred size after we placed it (origin kept):
    /// pull it back inside the visible frame (8 pt) without re-running layout.
    private func reclamp() {
        guard let panel, !placing else { return }
        let visible = (anchorAndScreen().1 ?? panel.screen ?? NSScreen.main)?.visibleFrame
        guard let visible else { return }
        let c = PopoverPlacement.clamp(panel.frame, visibleFrame: visible)
        if c != panel.frame {
            placing = true
            panel.setFrame(c, display: true)
            placing = false
        }
        panel.invalidateShadow()
    }

    /// The status button's rect and the screen its window is on (nil rect when the item is hidden).
    private func anchorAndScreen() -> (NSRect?, NSScreen?) {
        let a = anchor()
        let byPoint = a.flatMap { a in NSScreen.screens.first { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) } }
        let screen = byPoint ?? NSScreen.main
        return (byPoint == nil ? nil : a, screen)
    }

    private var placing = false
    private static let log = Logger(subsystem: "dev.telltale", category: "Popover")

    // MARK: Dismissal

    private func installMonitors() {
        // Clicks in other apps.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
                                                         Task { @MainActor in self?.close() }
                                                     }) {
            monitors.append(g)
        }
        // Clicks in our other windows (not the status button: its action toggles), Esc, ⌘ shortcuts.
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
                                                    handler: { [weak self] event in
                                                        // AppKit delivers local monitors on the main thread.
                                                        let consumed = MainActor.assumeIsolated {
                                                            self?.handleLocal(event) ?? false
                                                        }
                                                        return consumed ? nil : event
                                                    }) {
            monitors.append(l)
        }
    }

    /// True when the event is consumed.
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        switch event.type {
        case .keyDown:
            guard event.window === panel else { return false }
            if event.keyCode == 53 {                                    // Esc
                close()
                return true
            }
            return event.modifierFlags.contains(.command) && shortcuts(event)
        default:
            if event.window === panel { return false }
            if event.window?.className.contains("StatusBar") == true { return false }   // status button toggles
            close()
            return false
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
