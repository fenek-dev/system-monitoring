import AppKit
import MonitorLive
import MonitorModel
import MonitorRuntime
import MonitorScreens
import MonitorUIKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let env = AppEnvironment()
        self.env = env
        env.runtime.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Telltale")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Telltale", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
