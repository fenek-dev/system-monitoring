import AppKit
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

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard panel == nil else { return }
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
        onVisibilityChange(true)
    }

    func close() {
        guard let panel else { return }
        removeMonitors()
        sizeObservation = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
        self.panel = nil
        host = nil
        onVisibilityChange(false)
    }

    private func place() {
        guard let panel, let host else { return }
        var size = host.preferredContentSize
        if size.height < 10 { size = host.view.fittingSize }
        size.width = 360
        let a = anchor() ?? .zero
        let hit = NSScreen.screens.first { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) }
        guard let screen = hit ?? NSScreen.main else { return }
        // Before the status item window is placed (e.g. at launch) the anchor is off-screen: use the top right.
        let anchorRect = hit == nil ? NSRect(x: screen.frame.maxX - 200, y: screen.visibleFrame.maxY, width: 1, height: 1) : a
        let f = PopoverPlacement.frame(anchor: anchorRect, content: size, visibleFrame: screen.visibleFrame,
                                       screenFrame: screen.frame)
        panel.setFrame(f, display: true)
    }

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
