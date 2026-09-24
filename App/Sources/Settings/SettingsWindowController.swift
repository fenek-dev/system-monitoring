import AppKit
import MonitorScreens
import SwiftUI

/// Settings window (DESIGN §3.14): single instance, 520 wide, intrinsic height, not resizable, dashboard chrome
/// (52-pt titlebar, `TrafficLightsKeeper`). Released on close.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    private var lights: TrafficLightsKeeper?

    init(env: AppEnvironment) {
        self.env = env
    }

    func show() {
        let w = window ?? makeWindow()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        lights?.apply()
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let about = AboutInfo(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            historySize: { [dir = env.dataDirectory] in await Self.historySize(dir) })
        // Cap at the screen's visible height − 40: above it the sections scroll instead of clipping (13" screens).
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height
        let root = SettingsView(loginItem: LaunchAtLogin.control, about: about,
                                maxHeight: visible.map { $0 - 40 })
            .telltaleEnvironment(env.context())
        let host = NSHostingController(rootView: root)
        host.safeAreaRegions = []                                // header strip sits under the traffic lights
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "Settings"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0, blue: 0x1D / 255.0, alpha: 1)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.delegate = self
        w.center()
        window = w
        lights = TrafficLightsKeeper(window: w)
        return w
    }

    func windowWillClose(_ notification: Notification) {
        lights?.stop()
        lights = nil
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
    }

    /// Size of the store files in the data directory ("12.4 MB"); nil when none. Off the main actor: a data dir
    /// under ~/Documents triggers a TCC prompt and blocks the call until answered.
    @concurrent nonisolated static func historySize(_ dir: URL) async -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
