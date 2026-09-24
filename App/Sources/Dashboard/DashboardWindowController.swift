import AppKit
import MonitorModel
import MonitorScreens
import SwiftUI

/// Dashboard window (DESIGN §3.0, ARCHITECTURE §5.13): 1280×860 (min 1100×720), `.fullSizeContentView`,
/// transparent titlebar, hidden title, empty unified toolbar (52-pt titlebar), dark. Window and hosting view are
/// released on close; open/occlusion/miniaturize feed the `VisibilityTracker`.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private let visibility: VisibilityTracker
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(env: AppEnvironment, visibility: VisibilityTracker) {
        self.env = env
        self.visibility = visibility
    }

    var isOpen: Bool { window != nil }

    func show(page: DashboardPage? = nil) {
        env.navigation.open(page)
        let w = window ?? makeWindow()
        if w.isMiniaturized { w.deminiaturize(nil) }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        Self.layoutTrafficLights(w)
        visibility.update {
            $0.dashboardOpen = true
            $0.page = env.navigation.page                       // the nav observation catches up async
            $0.dashboardMiniaturized = w.isMiniaturized
            $0.dashboardOccluded = false                        // occlusion notifications correct this

        }
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let root = DashboardRoot().telltaleEnvironment(env.context())
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "Telltale"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0, blue: 0x1D / 255.0, alpha: 1)
        w.minSize = NSSize(width: 1100, height: 720)
        w.setContentSize(NSSize(width: 1280, height: 860))
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.delegate = self
        if !w.setFrameUsingName("TelltaleDashboard") { w.center() }
        w.setFrameAutosaveName("TelltaleDashboard")

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncOcclusion() }
            },
        ]
        window = w
        return w
    }

    /// DESIGN §3.0: traffic lights centered at y = 26 in a 52-pt titlebar, first light at x = 18, gap 8.
    /// (An empty unified `NSToolbar` gives the 52-pt titlebar, but its background hides the SwiftUI page header
    /// drawn under it, so the titlebar container is resized by hand instead.)
    static func layoutTrafficLights(_ w: NSWindow, height: CGFloat = 52, x: CGFloat = 18, gap: CGFloat = 8) {
        guard !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        var f = container.frame
        f.size.height = height
        f.origin.y = w.frame.height - height
        container.frame = f
        var nextX = x
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = w.standardWindowButton(kind) else { continue }
            b.setFrameOrigin(NSPoint(x: nextX, y: ((height - b.frame.height) / 2).rounded()))
            nextX += b.frame.width + gap
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window { Self.layoutTrafficLights(w) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let w = window { Self.layoutTrafficLights(w) }
    }

    private func syncOcclusion() {
        guard let w = window else { return }
        visibility.update { $0.dashboardOccluded = !w.occlusionState.contains(.visible) }
    }

    // MARK: NSWindowDelegate

    func windowDidMiniaturize(_ notification: Notification) {
        visibility.update { $0.dashboardMiniaturized = true }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        visibility.update { $0.dashboardMiniaturized = false }
    }

    func windowWillClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
        visibility.update {
            $0.dashboardOpen = false
            $0.dashboardOccluded = false
            $0.dashboardMiniaturized = false
        }
    }
}
