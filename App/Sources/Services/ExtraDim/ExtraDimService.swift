import AppKit
import ApplicationServices
import MonitorExtraDim
import MonitorScreens
import MonitorUIKit
import os

/// Extra Dim glue (extra-dim spec §3, §5): owns the pure `ExtraDimMachine`, feeds it key presses, watchdog ticks
/// and display events, and executes its actions on the adapters. Follows `settings.extraDimEnabled`; answers
/// Settings' status poll (creating the tap once Accessibility is granted). The dim level is never persisted.
@MainActor
final class ExtraDimService {
    static let watchdogInterval: TimeInterval = 1
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let settings: SettingsStore
    private var machine = ExtraDimMachine()
    private let display = BuiltinDisplay()
    private let gamma = GammaDimmer()
    private let hud = ExtraDimHUDPanel()
    private var tap: BrightnessKeyTap?
    private var tapFailed = false
    private var events: DisplayEvents?
    private var watchdog: Timer?
    private var loop: ObservationLoop<Bool>?
    /// The settings value last acted on (nil before launch's first sync).
    private var applied: Bool?
    private let log = Logger(subsystem: "dev.telltale", category: "ExtraDim")

    init(settings: SettingsStore) {
        self.settings = settings
        settings.refreshExtraDimStatus = { [weak self] in self?.refreshStatus() ?? .off }
        settings.openAccessibilitySettings = { NSWorkspace.shared.open(Self.accessibilitySettingsURL) }
        loop = ObservationLoop({ settings.extraDimEnabled }) { [weak self] on in self?.sync(on) }
    }

    /// `applicationWillTerminate`: restore gamma, drop the tap and observers.
    func shutdown() {
        loop?.cancel()
        loop = nil
        run(machine.handle(.setEnabled(false)).actions)
        removeTap()
        events?.stop()
        events = nil
        hud.hide()
    }

    // MARK: Enablement (spec §5.7)

    /// Launch (first call): tap silently if trusted, never prompt. Later toggle-on: prompt for Accessibility.
    private func sync(_ on: Bool) {
        let launch = applied == nil
        guard on != applied else { return }
        applied = on
        guard BuiltinDisplay.brightnessAvailable else {
            if on { log.notice("extra dim unavailable: DisplayServices not present") }
            return
        }
        if on {
            run(machine.handle(.setEnabled(true)).actions)
            events = events ?? DisplayEvents { [weak self] in self?.displayChanged() }
            tapFailed = false
            if launch ? AXIsProcessTrusted() : Self.promptForTrust() { installTap() }
        } else {
            run(machine.handle(.setEnabled(false)).actions)
            removeTap()
            events?.stop()
            events = nil
            tapFailed = false
        }
    }

    /// Settings' 1-s poll: picks up a grant made in System Settings (no notification exists) and a revoked one.
    private func refreshStatus() -> SettingsStore.ExtraDimStatus {
        guard BuiltinDisplay.brightnessAvailable else { return .unavailable }
        sync(settings.extraDimEnabled)                   // the toggle may have changed just before this poll
        guard settings.extraDimEnabled else { return .off }
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        if tap == nil && !tapFailed { installTap() }
        return tap != nil ? .active : .tapFailed
    }

    private static func promptForTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func installTap() {
        guard tap == nil else { return }
        tap = BrightnessKeyTap { [weak self] key in self?.keyDown(key) ?? false }
        tapFailed = tap == nil
        if tapFailed { log.error("brightness key tap creation failed with Accessibility granted") }
    }

    private func removeTap() {
        tap?.invalidate()
        tap = nil
    }

    // MARK: Inputs

    /// Tap callback (spec §5.1): only a brightness read and a machine step; the actions run after it returns.
    private func keyDown(_ key: ExtraDimMachine.Key) -> Bool {
        let level = display.id.flatMap { display.brightness($0) }
        let step = machine.handle(.key(key, brightness: level))
        if !step.actions.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.run(step.actions) }
            }
        }
        return step.consumeKey
    }

    /// Wake / screens wake / unlock / screen params (spec §5.4).
    private func displayChanged() {
        guard machine.level > 0 else { return }
        guard let id = display.id, id == gamma.display else {
            feed(.builtinDisplayGone)
            return
        }
        feed(.reapply)
    }

    /// Watchdog (spec §5.5): clears when the backlight went above min, re-applies on drift (fight guard in the machine).
    private func tick() {
        guard let id = display.id else {
            feed(.builtinDisplayGone)
            return
        }
        feed(.brightness(display.brightness(id)))
        guard machine.level > 0 else { return }
        if gamma.drifted(level: machine.level) == true { feed(.gammaDrift(at: Date())) }
    }

    private func feed(_ input: ExtraDimMachine.Input) {
        run(machine.handle(input).actions)
    }

    // MARK: Actions

    private func run(_ actions: [ExtraDimMachine.Action]) {
        for action in actions {
            switch action {
            case .captureBase:
                guard let id = display.id, gamma.captureBase(id) else { return feed(.gammaFailed) }
            case .applyGamma(let level):
                guard gamma.apply(level: level) else { return feed(.gammaFailed) }
            case .restoreGamma:
                gamma.restore()
            case .showHUD(let content):
                if content == .resetByOtherApp { log.notice("extra dim reset: another app keeps writing the gamma table") }
                hud.show(Self.hudContent(content), on: gamma.display.flatMap(display.screen) ?? display.id.flatMap(display.screen))
            case .startWatchdog:
                startWatchdog()
            case .stopWatchdog:
                watchdog?.invalidate()
                watchdog = nil
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    static func hudContent(_ hud: ExtraDimMachine.HUD) -> TTExtraDimHUD.Content {
        switch hud {
        case .level(let n): .level(n)
        case .resetByOtherApp: .resetByOtherApp
        case .cannotDim: .cannotDim
        }
    }
}
