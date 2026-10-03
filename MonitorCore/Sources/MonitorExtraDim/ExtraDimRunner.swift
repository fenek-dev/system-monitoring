import Foundation

/// The side effects `ExtraDimRunner` drives (the app's adapters; fakes in tests).
@MainActor
public protocol ExtraDimEffects: AnyObject {
    /// False when the table could not be read (→ `.gammaFailed`).
    func captureBase() -> Bool
    /// False when the write failed (→ `.gammaFailed`).
    func applyGamma(level: Int) -> Bool
    /// Never gated on the machine level: restoring with nothing captured is a no-op.
    func restoreGamma()
    func gammaDrift(level: Int) -> GammaSession.Drift
    func showHUD(_ hud: ExtraDimMachine.HUD)
    func startWatchdog()
    func stopWatchdog()
    /// Call `drain()` soon, after the current event-tap callback returns (`DispatchQueue.main.async` in the app).
    func scheduleDrain()
}

/// Runs `ExtraDimMachine` actions on `ExtraDimEffects`, in the order the machine emitted them (extra-dim spec §5).
///
/// Key presses step the machine inside the event-tap callback, but their effects are queued (`pending`) and run by
/// `drain()` after the callback returns (§5.1). Every other input drains the queue first, so effects always run in
/// machine order. `disable()` discards the queue instead — a toggle-off must never be followed by a stale queued
/// capture/apply — and restores unconditionally. A failed capture/apply/read becomes `.gammaFailed` (§7) and
/// discards the rest of the queue, whose actions belong to a state the machine just left.
@MainActor
public final class ExtraDimRunner {
    public weak var effects: ExtraDimEffects?
    public private(set) var machine: ExtraDimMachine
    public private(set) var pending: [ExtraDimMachine.Action] = []

    public init(machine: ExtraDimMachine = ExtraDimMachine()) {
        self.machine = machine
    }

    /// Event-tap path: steps the machine now, queues its effects. Returns whether to swallow the key.
    public func keyDown(_ key: ExtraDimMachine.Key, brightness: Float?) -> Bool {
        let step = machine.handle(.key(key, brightness: brightness))
        if !step.actions.isEmpty {
            let schedule = pending.isEmpty
            pending += step.actions
            if schedule { effects?.scheduleDrain() }
        }
        return step.consumeKey
    }

    /// Runs the queued key effects.
    public func drain() {
        let batch = pending
        pending = []
        run(batch)
    }

    /// Any non-key input: queued effects first, then this input's.
    public func send(_ input: ExtraDimMachine.Input) {
        drain()
        run(machine.handle(input).actions)
    }

    public func enable() {
        send(.setEnabled(true))
    }

    /// Toggle off / quit: drops queued effects, clears the machine, then restores and stops the watchdog whatever
    /// the level said.
    public func disable() {
        pending = []
        run(machine.handle(.setEnabled(false)).actions)
        effects?.restoreGamma()
        effects?.stopWatchdog()
    }

    /// Watchdog tick (§5.5). Unreadable brightness skips the whole tick (no drift accounting); a readable one above
    /// min clears; otherwise the live table is compared — drift feeds the fight guard, an unreadable table fails.
    public func watchdogTick(brightness: Float?, now: Date) {
        drain()
        guard brightness != nil else { return }
        send(.brightness(brightness))
        guard machine.level > 0, let effects else { return }
        switch effects.gammaDrift(level: machine.level) {
        case .none: break
        case .drifted: send(.gammaDrift(at: now))
        case .unreadable: send(.gammaFailed)
        }
    }

    private func run(_ actions: [ExtraDimMachine.Action]) {
        guard let effects else { return }
        for action in actions {
            let ok: Bool
            switch action {
            case .captureBase: ok = effects.captureBase()
            case .applyGamma(let level): ok = effects.applyGamma(level: level)
            case .restoreGamma: effects.restoreGamma(); ok = true
            case .showHUD(let hud): effects.showHUD(hud); ok = true
            case .startWatchdog: effects.startWatchdog(); ok = true
            case .stopWatchdog: effects.stopWatchdog(); ok = true
            }
            if !ok {
                pending = []
                run(machine.handle(.gammaFailed).actions)
                return
            }
        }
    }
}
