import AppKit
import MonitorLive
import MonitorModel
import MonitorRuntime
import MonitorScreens
import MonitorUIKit
import os

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment!
    private var statusItem: StatusItemController!
    private var popover: PopoverPanelController!
    private var visibility: VisibilityTracker!
    private let log = Logger(subsystem: "dev.telltale", category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let env = AppEnvironment()
        self.env = env

        visibility = VisibilityTracker { [log, env] v in
            env.live.isPresenting = v.mode == .interactive
            env.runtime.setVisibility(v)
            log.info("visibility mode=\(v.mode == .interactive ? "interactive" : "background", privacy: .public) popover=\(v.popoverOpen) dashboard=\(v.dashboardVisible) page=\(v.page?.rawValue ?? "-", privacy: .public) demand=\(v.demand.rawValue)")
        }
        statusItem = StatusItemController(live: env.live, onToggle: { [weak self] in self?.togglePopover() },
                                          menu: { [weak self] in self?.statusMenu() ?? NSMenu() })
        popover = PopoverPanelController(
            env: env,
            anchor: { [weak self] in self?.statusItem.buttonScreenFrame },
            onVisibilityChange: { [weak self] open in
                self?.statusItem.setHighlighted(open)
                self?.visibility.update { $0.popoverOpen = open }
            },
            shortcuts: { [weak self] e in self?.handleShortcut(e) ?? false })

        #if DEBUG
        if let level = env.options.statusPreview {
            let preview = AlertState.preview(level, pulseToken: 1)
            statusItem.previewState = preview
            if level == .critical { statusItem.runPulse(preview) }
        }
        #endif
        env.runtime.start()

        if env.options.openPopover {
            // Let the status item window get its menu bar position first (the popover anchors to it).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.popover.open()
            }
        }
        #if DEBUG
        if let n = ProcessInfo.processInfo.environment["TELLTALE_POPOVER_CYCLES"].flatMap(Int.init) {
            runPopoverCycles(n)
        }
        #endif
    }

    // MARK: Commands

    func togglePopover() { popover.toggle() }

    /// ⌘ shortcuts while the (non-activating) popover is key.
    private func handleShortcut(_ e: NSEvent) -> Bool {
        switch e.charactersIgnoringModifiers {
        case "q": NSApp.terminate(nil)
        case ",": openSettingsAction()
        case "d": openDashboardAction()
        default: return false
        }
        return true
    }

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

    // MARK: DEBUG verification aids

    #if DEBUG
    /// `TELLTALE_POPOVER_CYCLES=N`: open/close the popover N times (T3 memory check), logging RSS.
    private func runPopoverCycles(_ n: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let cold = Self.residentMB()
            for _ in 0..<2 {                                    // warm-up: first hosting loads SwiftUI/fonts
                popover.open()
                try? await Task.sleep(for: .milliseconds(300))
                popover.close()
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            let start = Self.residentMB()
            log.notice("popover cycles cold rss=\(cold, format: .fixed(precision: 1)) MB, after warm-up=\(start, format: .fixed(precision: 1)) MB")
            log.notice("popover cycles start rss=\(start, format: .fixed(precision: 1)) MB")
            for _ in 0..<n {
                popover.open()
                try? await Task.sleep(for: .milliseconds(300))
                popover.close()
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            let end = Self.residentMB()
            log.notice("popover cycles n=\(n) end rss=\(end, format: .fixed(precision: 1)) MB delta=\(end - start, format: .fixed(precision: 1)) MB")
        }
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    #endif
}
