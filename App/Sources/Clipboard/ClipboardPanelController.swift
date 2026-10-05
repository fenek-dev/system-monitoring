import AppKit
import ClipboardCore
import MonitorScreens
import SwiftUI

/// The clipboard picker's window: a borderless non-activating panel (`PopoverPanel`, so it can be key without
/// activating Warden) at the cursor. The SwiftUI tree exists only while shown. Key events are mapped to
/// `ClipboardPickerModel.handle` before the search field sees them.
@MainActor
final class ClipboardPanelController {
    private let model: ClipboardPickerModel
    private let onClose: @MainActor () -> Void

    private var panel: PopoverPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(model: ClipboardPickerModel, onClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    var isShown: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        let size = ClipboardPickerView.size
        let panel = PopoverPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                          // the view clips itself to rounded corners; the shadow follows
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityLabel("Clipboard History")
        panel.contentView = NSHostingView(rootView: ClipboardPickerView(model: model))
        panel.setFrame(Self.frame(size: size), display: false)

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors(for: panel)
        // First layout pass can finish after this turn; the shadow is computed from the drawn alpha.
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.close()
        panel.contentView = nil
        onClose()
    }

    private func installMonitors(for panel: PopoverPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers local monitors on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        // An input method is composing in the search field: Return, arrows and Esc belong to it.
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        if let command = ClipboardPickerKey.command(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue) {
            return model.handle(command)
        }
        return sendEditingShortcut(event)
    }

    /// The app is not active, so the main menu does not resolve ⌘A/C/V/X/Z: send them down the responder chain
    /// ourselves so the search field supports them.
    private func sendEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
        let action: Selector
        switch event.charactersIgnoringModifiers {
        case "a": action = #selector(NSText.selectAll(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "z": action = Selector(("undo:"))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    private static func frame(size: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        return ClipboardPanelPlacement.frame(mouse: mouse, size: size, visibleFrame: visible)
    }
}
