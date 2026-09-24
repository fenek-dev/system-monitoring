import AppKit
import MonitorLive
import MonitorModel
import MonitorRuntime
import MonitorScreens
import MonitorUIKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let env = AppEnvironment()
        self.env = env

        statusItem = StatusItemController(live: env.live, onToggle: { [weak self] in self?.togglePopover() },
                                          menu: { [weak self] in self?.statusMenu() ?? NSMenu() })
        #if DEBUG
        if let level = env.options.statusPreview {
            let preview = AlertState.preview(level, pulseToken: 1)
            statusItem.previewState = preview
            if level == .critical { statusItem.runPulse(preview) }
        }
        #endif
        env.runtime.start()
    }

    // MARK: Commands

    func togglePopover() {}

    private func statusMenu() -> NSMenu {
        let paused = env.live.alert.paused
        let menu = NSMenu()
        menu.addItem(item("Open Dashboard", #selector(openDashboardAction), "d"))
        menu.addItem(item(paused ? "Resume Sampling" : "Pause Sampling", #selector(togglePauseAction), ""))
        menu.addItem(item("Settings…", #selector(openSettingsAction), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Telltale", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc private func openDashboardAction() {}
    @objc private func togglePauseAction() {}
    @objc private func openSettingsAction() {}
}
