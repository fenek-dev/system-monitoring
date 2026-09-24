import AppKit

/// DESIGN §3.0: traffic lights centered at y = 26 in a 52-pt titlebar, first light at x = 18, gap 8.
///
/// The supported route (empty unified `NSToolbar` → 52-pt titlebar) draws a toolbar background over the SwiftUI
/// page header underneath it, so the header disappears. Instead the titlebar container is resized and the three
/// standard buttons (public API: `standardWindowButton`) are moved. The container is the private titlebar view;
/// when that hierarchy is not what we expect, nothing is touched and the system positions stay (degrades to the
/// default 28-pt titlebar look). AppKit re-lays the buttons out on key/main/appearance/resize/full-screen changes,
/// so the keeper re-applies after each of them.
@MainActor
final class TrafficLightsKeeper {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    init(window: NSWindow) {
        self.window = window
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.apply() }
        }
        apply()
    }

    func apply() {
        guard let window else { return }
        Self.layout(window)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        appearanceObservation = nil
    }

    static func layout(_ w: NSWindow, height: CGFloat = 52, x: CGFloat = 18, gap: CGFloat = 8) {
        guard !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let container = close.superview?.superview,
              String(describing: type(of: container)).contains("Titlebar") else { return }
        var f = container.frame
        if f.height != height || f.origin.y != w.frame.height - height {
            f.size.height = height
            f.origin.y = w.frame.height - height
            container.frame = f
        }
        var nextX = x
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = w.standardWindowButton(kind) else { continue }
            let origin = NSPoint(x: nextX, y: ((height - b.frame.height) / 2).rounded())
            if b.frame.origin != origin { b.setFrameOrigin(origin) }
            nextX += b.frame.width + gap
        }
    }
}
