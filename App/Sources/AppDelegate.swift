import AppKit
import MonitorLive
import MonitorModel
import MonitorRuntime
import MonitorScreens
import MonitorUIKit
import os

/// AppKit lifecycle + composition of the shell controllers (ARCHITECTURE §5.13).
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment!
    private var statusItem: StatusItemController!
    private var popover: PopoverPanelController!
    private var dashboard: DashboardWindowController!
    private var settingsWindow: SettingsWindowController!
    private var visibility: VisibilityWiring!
    private var overlay: OverlayPanelController!
    private var hotKey: GlobalHotKey?
    /// Settings' recorder is capturing keys: the global hotkey stays unregistered until it stops.
    private var hotKeyRecording = false
    private var overlayLoop: ObservationLoop<Bool>?
    private var hotKeyLoop: ObservationLoop<HotKeySpec>?
    private var power: PowerEvents?
    private var termination: TerminationController?
    /// Held for the process lifetime: one instance per data dir (A-M1 ruling).
    private var instanceLock: InstanceLock?
    private var activationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "dev.telltale", category: "App")

    /// Single instance per data dir: take the lock, or ask the running instance to open its dashboard and exit
    /// before a second runtime (status item, sampler, store writer) is built.
    /// Registers the "open your dashboard" listener right after taking the lock, before the environment is built, so
    /// a launch that races ours is never lost: a request arriving before the controllers exist is kept and served
    /// once they do (`serveActivation`).
    private func claimSingleInstance(_ options: LaunchOptions) {
        let dir = options.dataDirectory ?? AppEnvironment.defaultDataDirectory()
        switch InstanceLock.acquire(dataDirectory: dir) {
        case .acquired(let lock):
            instanceLock = lock
        case .heldByAnotherInstance:
            log.notice("already running on \(dir.path, privacy: .public); activating that instance")
            InstanceActivation.post(dataDirectory: dir, page: options.openDashboard)
            exit(0)
        case .unavailable(let why):
            log.error("instance lock unavailable (\(why, privacy: .public)); continuing")
        }
        activationObserver = InstanceActivation.observe(dataDirectory: dir) { [weak self] page in
            guard let self else { return }
            log.notice("second launch → open dashboard")
            if launched {
                env.commands.openDashboard(page)
            } else {
                pendingActivation = .some(page)
            }
        }
    }

    private var launched = false
    /// An activation request received before launch finished (the inner value is the requested page, if any).
    private var pendingActivation: DashboardPage??

    private func serveActivation() {
        launched = true
        if let page = pendingActivation {
            pendingActivation = nil
            env.commands.openDashboard(page)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(arguments: ProcessInfo.processInfo.arguments,
                                          environment: ProcessInfo.processInfo.environment)
        if let cmd = options.loginItemCommand {
            runLoginItemCommand(cmd)                                // CLI check; never starts the runtime
        }
        LegacyMigrationRunner.run(options)                          // Telltale → Warden, once; before any store opens
        claimSingleInstance(options)                                // exits if another instance owns the data dir
        DispatchQueue.global(qos: .utility).async { LiveProcessSampler.pruneReports() }   // [Sample] reports > 1 day
        // Dark per window (panel, dashboard, settings), never app-wide: the status bar button must keep the
        // menu bar's own appearance so `labelColor` in the glyph follows a light or dark menu bar.
        let env = AppEnvironment()
        self.env = env
        env.commands = makeCommands()
        env.processActions = env.options.mockScenario == nil ? ProcessActionsLive.make() : .noop

        visibility = VisibilityWiring(env: env)
        statusItem = StatusItemController(live: env.live, onToggle: { [weak self] in self?.popover.toggle() },
                                          menu: { [weak self] in self?.statusMenu() ?? NSMenu() })
        popover = PopoverPanelController(
            env: env,
            anchor: { [weak self] in self?.statusItem.buttonScreenFrame },
            anchorScreen: { [weak self] in self?.statusItem.buttonScreen },
            onVisibilityChange: { [weak self] open in
                self?.statusItem.setHighlighted(open)
                self?.visibility.tracker.update { $0.popoverOpen = open }
            },
            shortcuts: { [weak self] e in self?.handleShortcut(e) ?? false })
        statusItem.willShowMenu = { [weak self] in self?.popover.close() }
        dashboard = DashboardWindowController(env: env, visibility: visibility.tracker)
        settingsWindow = SettingsWindowController(env: env)
        overlay = OverlayPanelController(env: env, onVisibilityChange: { [weak self] shown in
            self?.visibility.tracker.update { $0.overlayVisible = shown }
        })
        installOverlayWiring()
        power = PowerEvents(willSleep: { env.runtime.systemWillSleep() }, didWake: { env.runtime.systemDidWake() })
        NSApp.mainMenu = mainMenu()
        installTerminationSignal()
        serveActivation()

        #if DEBUG
        if let level = env.options.statusPreview {
            let preview = AlertState.preview(level, pulseToken: 1)
            statusItem.previewState = preview
            if level == .critical { statusItem.runPulse(preview) }
        }
        #endif
        env.runtime.start()
        log.notice("started")

        let o = env.options
        if o.openPopover || o.openDashboard != nil || o.openSettings {
            // Let the status item window get its menu bar position first (the popover anchors to it).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if let page = o.openDashboard { dashboard.show(page: page) }
                if o.openSettings { settingsWindow.show() }
                if o.openPopover { popover.open() }
            }
        }
        #if DEBUG
        if let n = ProcessInfo.processInfo.environment["TELLTALE_POPOVER_CYCLES"].flatMap(Int.init) {
            runPopoverCycles(n)
        }
        if ProcessInfo.processInfo.environment["TELLTALE_VISIBILITY_DRILL"] != nil { runVisibilityDrill() }
        #endif
    }

    // MARK: Termination (ARCHITECTURE §4): .terminateLater → await runtime.shutdown() (≤ 3 s) → reply

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if termination == nil {
            let env = self.env!
            termination = TerminationController(
                timeout: .seconds(3),
                closeUI: { [weak self] in
                    self?.popover.close()
                    self?.dashboard.close()
                    self?.settingsWindow.close()
                    self?.overlayLoop?.cancel()
                    self?.overlay.hide()
                    self?.power?.stop()
                },
                shutdown: { await env.runtime.shutdown() },
                reply: { ok in NSApp.reply(toApplicationShouldTerminate: ok) })
        }
        termination?.requestTermination()
        return .terminateLater
    }

    /// Quit from code. `terminate` answers `.terminateLater` and AppKit then spins a nested event loop until the
    /// reply; called from inside a main-queue job (any MainActor `Task`), that job blocks the serial main queue, so
    /// the shutdown Task could never run (deadlock seen with SIGTERM). A run-loop perform escapes the job first.
    static func requestQuit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// `--login-item register|unregister|status`: acts on `SMAppService.mainApp`, logs + prints the status, exits.
    private func runLoginItemCommand(_ cmd: String) -> Never {
        var code: Int32 = 0
        do {
            switch cmd {
            case "register": try LaunchAtLogin.setEnabled(true)
            case "unregister": try LaunchAtLogin.setEnabled(false)
            default: break
            }
        } catch {
            log.error("login item \(cmd, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            print("login-item \(cmd) failed: \(error.localizedDescription)")
            code = 1
        }
        let status = String(describing: LaunchAtLogin.status)
        log.notice("login item status=\(status, privacy: .public) bundle=\(Bundle.main.bundlePath, privacy: .public)")
        print("login-item status=\(status) bundle=\(Bundle.main.bundlePath)")
        exit(code)
    }

    /// SIGTERM (scripts `kill -TERM <pid>`, `launchctl`) takes the same graceful path as ⌘Q.
    private var sigterm: DispatchSourceSignal?
    private func installTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { Task { @MainActor in AppDelegate.requestQuit() } }
        src.resume()
        sigterm = src
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dashboard.show() }
        return true
    }

    // MARK: Commands (AppCommands, environment-injected)

    private func makeCommands() -> AppCommands {
        AppCommands(
            openDashboard: { [weak self] page in
                self?.popover.close()
                self?.dashboard.show(page: page)
            },
            inspectApp: { [weak self] key in
                guard let self else { return }
                popover.close()
                env.navigation.inspect(key)
                dashboard.show(page: .processes)
            },
            openSettings: { [weak self] in
                self?.popover.close()
                self?.settingsWindow.show()
            },
            setPaused: { [weak self] p in self?.setPaused(p) },
            closePopover: { [weak self] in self?.popover.close() },
            quitTelltale: { AppDelegate.requestQuit() },
            toggleOverlay: { [weak self] in self?.toggleOverlay() },
            setHotKeyRecording: { [weak self] recording in self?.setHotKeyRecording(recording) })
    }

    // MARK: Overlay (spec 2026-09-25 overlay)

    /// Panel follows `settings.overlayEnabled` (opacity and corner are followed by the controller itself);
    /// the global hotkey follows `settings.overlayHotKey` and publishes its status for Settings.
    private func installOverlayWiring() {
        let settings = env.settings
        overlayForced = env.options.overlay
        overlayLoop = ObservationLoop({ settings.overlayEnabled }) { [weak self] _ in self?.applyOverlay() }
        hotKeyLoop = ObservationLoop({ settings.overlayHotKey }) { [weak self] _ in self?.registerHotKey() }
    }

    /// `--overlay`: shown for this run without touching `settings.overlayEnabled`; the first toggle clears it.
    private var overlayForced = false

    private func applyOverlay() {
        if env.settings.overlayEnabled || overlayForced { overlay.show() } else { overlay.hide() }
    }

    /// Hotkey, popover footer: flip what is on screen and persist it.
    private func toggleOverlay() {
        let on = !overlay.isShown
        overlayForced = false
        env.settings.overlayEnabled = on
        applyOverlay()
        log.notice("overlay \(on ? "on" : "off", privacy: .public)")
    }

    private func setHotKeyRecording(_ recording: Bool) {
        guard recording != hotKeyRecording else { return }
        hotKeyRecording = recording
        registerHotKey()
    }

    /// Drops the current registration, then registers `settings.overlayHotKey` unless the recorder is capturing.
    private func registerHotKey() {
        hotKey?.invalidate()
        hotKey = nil
        guard !hotKeyRecording else { return }
        hotKey = GlobalHotKey(spec: env.settings.overlayHotKey) { [weak self] in self?.toggleOverlay() }
        env.hotKeyState.status = hotKey == nil ? .unavailable : .registered
    }

    private func setPaused(_ p: Bool) {
        env.runtime.setPaused(p)
        // The pipeline may apply the pause to the live model asynchronously; make the glyph/header follow now.
        if env.live.alert.paused != p { env.live.setPaused(p, at: Date()) }
        log.notice("sampling \(p ? "paused" : "resumed", privacy: .public)")
    }

    /// ⌘ shortcuts while the (non-activating) popover is key.
    private func handleShortcut(_ e: NSEvent) -> Bool {
        switch e.charactersIgnoringModifiers {
        case "q": AppDelegate.requestQuit()
        case ",": env.commands.openSettings()
        case "d": env.commands.openDashboard(.overview)
        default: return false
        }
        return true
    }

    // MARK: Menus

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Dashboard", #selector(openDashboardAction), "d"))
        menu.addItem(item(env.live.alert.paused ? "Resume Sampling" : "Pause Sampling", #selector(togglePauseAction), ""))
        menu.addItem(item("Settings…", #selector(openSettingsAction), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Warden", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    /// Key equivalents while a Telltale window is key (accessory apps show no menu bar, but the main menu still
    /// resolves ⌘Q, ⌘,, ⌘D, ⌘W, ⌘M and text editing).
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Warden")
        app.addItem(item("Open Dashboard", #selector(openDashboardAction), "d"))
        app.addItem(item("Settings…", #selector(openSettingsAction), ","))
        app.addItem(item("Pause/Resume Sampling", #selector(togglePauseAction), "p"))
        app.addItem(.separator())
        app.addItem(item("Quit Warden", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(NSMenuItem(title: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc private func openDashboardAction() { env.commands.openDashboard(nil) }
    @objc private func togglePauseAction() { env.commands.setPaused(!env.live.alert.paused) }
    @objc private func openSettingsAction() { env.commands.openSettings() }

    // MARK: DEBUG verification aids

    #if DEBUG
    /// `TELLTALE_POPOVER_CYCLES=N`: open/close the popover N times after 2 warm-up cycles (T3 memory check).
    private func runPopoverCycles(_ n: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let cold = Self.residentMB()
            for _ in 0..<2 { await cycle() }
            try? await Task.sleep(for: .seconds(1))
            let start = Self.residentMB()
            log.notice("popover cycles cold rss=\(cold, format: .fixed(precision: 1)) MB, after warm-up=\(start, format: .fixed(precision: 1)) MB")
            for _ in 0..<n { await cycle() }
            try? await Task.sleep(for: .seconds(1))
            let end = Self.residentMB()
            log.notice("popover cycles n=\(n) end rss=\(end, format: .fixed(precision: 1)) MB delta=\(end - start, format: .fixed(precision: 1)) MB")
        }
    }

    /// `TELLTALE_VISIBILITY_DRILL=1`: dashboard open → miniaturize → restore → Thermals → inspect app → close,
    /// 2 s apart, through the real AppKit window paths (T4 log check).
    private func runVisibilityDrill() {
        Task { @MainActor [weak self] in
            let step: Duration = .seconds(2)
            try? await Task.sleep(for: step)
            guard let self else { return }
            log.notice("drill: open dashboard")
            env.commands.openDashboard(.cpu)
            try? await Task.sleep(for: step)
            log.notice("drill: miniaturize")
            NSApp.windows.first { $0.title == "Warden" }?.miniaturize(nil)
            try? await Task.sleep(for: step)
            log.notice("drill: deminiaturize")
            env.commands.openDashboard(nil)
            try? await Task.sleep(for: step)
            log.notice("drill: page thermals")
            env.navigation.page = .thermals
            try? await Task.sleep(for: step)
            log.notice("drill: inspect app")
            env.commands.inspectApp(AppKey(kind: .app, id: "com.apple.Safari"))
            try? await Task.sleep(for: step)
            log.notice("drill: close dashboard")
            dashboard.close()
        }
    }

    private func cycle() async {
        popover.open()
        try? await Task.sleep(for: .milliseconds(300))
        popover.close()
        try? await Task.sleep(for: .milliseconds(200))
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
