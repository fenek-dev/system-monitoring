import AppKit
import ApplicationServices
import MonitorExtraDim
import MonitorScreens
import MonitorUIKit
import os

/// Extra Dim glue (extra-dim spec §3, §5): feeds key presses, watchdog ticks and display events to
/// `ExtraDimRunner` (machine + ordered effect queue) and implements its effects on the adapters. Follows
/// `settings.extraDimEnabled`; answers Settings' status poll (creating the tap once Accessibility is granted).
/// The dim level is never persisted.
@MainActor
final class ExtraDimService: ExtraDimEffects {
    static let watchdogInterval: TimeInterval = 1
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let settings: SettingsStore
    private let runner = ExtraDimRunner()
    private let display = BuiltinDisplay()
    private let gamma = GammaSession(device: GammaDimmer())
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
        runner.effects = self
        settings.refreshExtraDimStatus = { [weak self] in self?.refreshStatus() ?? .off }
        settings.openAccessibilitySettings = { NSWorkspace.shared.open(Self.accessibilitySettingsURL) }
        loop = ObservationLoop({ settings.extraDimEnabled }) { [weak self] on in self?.sync(on) }
    }

    /// `applicationWillTerminate`: drop queued effects, restore gamma (ColorSync if the base write fails), drop the
    /// tap and observers.
    func shutdown() {
        loop?.cancel()
        loop = nil
        runner.disable()
        gamma.restore(fallback: true)
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
            runner.enable()
            events = events ?? DisplayEvents { [weak self] in self?.displayChanged() }
            tapFailed = false
            if launch ? AXIsProcessTrusted() : Self.promptForTrust() { installTap() }
        } else {
            runner.disable()
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

    /// Tap callback (spec §5.1): only a brightness read and a machine step; the runner queues the effects.
    private func keyDown(_ key: ExtraDimMachine.Key) -> Bool {
        runner.keyDown(key, brightness: display.id.flatMap { display.brightness($0) })
    }

    /// Wake / screens wake / unlock / screen params (spec §5.4).
    private func displayChanged() {
        guard runner.machine.level > 0 else { return }
        guard let id = display.id, id == gamma.display else {
            runner.send(.builtinDisplayGone)
            return
        }
        runner.send(.reapply)
    }

    /// Watchdog (spec §5.5); the skip/clear/drift/fight-guard logic is in the runner and machine.
    private func tick() {
        guard let id = display.id, id == gamma.display else {
            runner.send(.builtinDisplayGone)
            return
        }
        runner.watchdogTick(brightness: display.brightness(id), now: Date())
    }

    // MARK: ExtraDimEffects

    func captureBase() -> Bool {
        guard let id = display.id else { return false }
        return gamma.captureBase(id)
    }

    func applyGamma(level: Int) -> Bool {
        gamma.apply(level: level)
    }

    /// A failed write keeps the base (spec §7). Built-in display still online → retry, then fall back to ColorSync;
    /// display gone → keep it: `captureBase` recovers it before any recapture.
    func restoreGamma() {
        guard !gamma.restore() else { return }
        if let id = display.id, id == gamma.display {
            gamma.restore(fallback: true)
        } else {
            log.notice("gamma restore deferred: built-in display offline")
        }
    }

    func gammaDrift(level: Int) -> GammaSession.Drift {
        gamma.drift(level: level)
    }

    func showHUD(_ content: ExtraDimMachine.HUD) {
        switch content {
        case .resetByOtherApp: log.notice("extra dim reset: another app keeps writing the gamma table")
        case .cannotDim: log.error("extra dim reset: gamma table capture/write/read failed")
        case .level: break
        }
        hud.show(Self.hudContent(content), on: display.id.flatMap(display.screen))
    }

    func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    func scheduleDrain() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.runner.drain() }
        }
    }

    static func hudContent(_ hud: ExtraDimMachine.HUD) -> TTExtraDimHUD.Content {
        switch hud {
        case .level(let n): .level(n)
        case .resetByOtherApp: .resetByOtherApp
        case .cannotDim: .cannotDim
        }
    }
}
