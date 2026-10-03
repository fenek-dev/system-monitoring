import Foundation
import Testing
@testable import MonitorExtraDim

/// Records every effect; `scheduleDrain` only counts (the test decides when the queued batch runs).
@MainActor
final class FakeEffects: ExtraDimEffects {
    enum Call: Equatable {
        case capture, apply(Int), restore, drift, hud(ExtraDimMachine.HUD), startWatchdog, stopWatchdog
    }

    var calls: [Call] = []
    var drainsScheduled = 0
    var captureOK = true
    var applyOK = true
    var drift: GammaSession.Drift = .none
    /// Level currently on screen (0 = normal), as the gamma effects left it.
    var shownLevel = 0

    func captureBase() -> Bool { calls.append(.capture); return captureOK }
    func applyGamma(level: Int) -> Bool {
        calls.append(.apply(level))
        if applyOK { shownLevel = level }
        return applyOK
    }
    func restoreGamma() { calls.append(.restore); shownLevel = 0 }
    func gammaDrift(level: Int) -> GammaSession.Drift { calls.append(.drift); return drift }
    func showHUD(_ hud: ExtraDimMachine.HUD) { calls.append(.hud(hud)) }
    func startWatchdog() { calls.append(.startWatchdog) }
    func stopWatchdog() { calls.append(.stopWatchdog) }
    func scheduleDrain() { drainsScheduled += 1 }
}

@MainActor
private func runner(level: Int = 0) -> (ExtraDimRunner, FakeEffects) {
    let r = ExtraDimRunner(machine: ExtraDimMachine(enabled: true, level: level))
    let e = FakeEffects()
    r.effects = e
    return (r, e)
}

private let t0 = Date(timeIntervalSince1970: 1_000)

@Suite @MainActor struct ExtraDimRunnerTests {
    @Test func keyEffectsAreQueuedUntilDrain() {
        let (r, e) = runner()
        #expect(r.keyDown(.down, brightness: 0))
        #expect(r.keyDown(.down, brightness: 0))
        #expect(e.calls.isEmpty)
        #expect(e.drainsScheduled == 1)                 // one async drain per non-empty queue
        r.drain()
        #expect(e.calls == [.capture, .apply(1), .hud(.level(1)), .startWatchdog, .apply(2), .hud(.level(2))])
        #expect(e.shownLevel == 2)
    }

    /// Finding: a toggle-off between the key and its queued drain left the display dimmed with level 0.
    @Test func toggleOffBeforeQueuedDrainNeverDims() {
        let (r, e) = runner()
        #expect(r.keyDown(.down, brightness: 0))
        r.disable()
        r.drain()                                       // the queued main.async block runs late
        #expect(!e.calls.contains(.capture))
        #expect(!e.calls.contains { if case .apply = $0 { true } else { false } })
        #expect(e.calls.suffix(2) == [.restore, .stopWatchdog])
        #expect(e.shownLevel == 0)
        #expect(r.machine.level == 0 && !r.machine.enabled)
    }

    @Test func disableRestoresEvenAtLevelZero() {
        let (r, e) = runner()
        r.disable()
        #expect(e.calls == [.restore, .stopWatchdog])
    }

    @Test func otherInputsRunAfterQueuedKeyEffectsInOrder() {
        let (r, e) = runner()
        _ = r.keyDown(.down, brightness: 0)
        r.send(.reapply)
        #expect(e.calls == [.capture, .apply(1), .hud(.level(1)), .startWatchdog, .apply(1)])
        r.drain()
        #expect(e.calls.count == 5)                     // the queue ran once
    }

    @Test func clearAfterQueuedKeyRunsInOrder() {
        let (r, e) = runner()
        _ = r.keyDown(.down, brightness: 0)
        r.send(.builtinDisplayGone)
        #expect(e.calls == [.capture, .apply(1), .hud(.level(1)), .startWatchdog, .restore, .stopWatchdog])
        #expect(e.shownLevel == 0)
    }

    @Test func captureFailureResetsAndDropsTheRestOfTheQueue() {
        let (r, e) = runner()
        e.captureOK = false
        _ = r.keyDown(.down, brightness: 0)
        _ = r.keyDown(.down, brightness: 0)
        r.drain()
        #expect(e.calls == [.capture, .restore, .stopWatchdog, .hud(.cannotDim)])
        #expect(r.machine.level == 0)
        #expect(r.pending.isEmpty)
    }

    @Test func applyFailureResets() {
        let (r, e) = runner(level: 2)
        e.applyOK = false
        r.send(.reapply)
        #expect(e.calls == [.apply(2), .restore, .stopWatchdog, .hud(.cannotDim)])
        #expect(r.machine.level == 0)
    }

    /// Finding: unreadable brightness must skip the whole tick — no gamma read, no drift accounting.
    @Test func watchdogSkipsTickWhenBrightnessUnreadable() {
        let (r, e) = runner(level: 3)
        e.drift = .drifted
        let before = r.machine.driftTimes
        r.watchdogTick(brightness: nil, now: t0)
        #expect(e.calls.isEmpty)
        #expect(r.machine.driftTimes == before)
        #expect(r.machine.level == 3)
    }

    @Test func watchdogBrightnessAboveMinClearsWithoutReadingGamma() {
        let (r, e) = runner(level: 3)
        r.watchdogTick(brightness: 0.5, now: t0)
        #expect(e.calls == [.restore, .stopWatchdog])
        #expect(r.machine.level == 0)
    }

    @Test func watchdogDriftReappliesThenFightGuardGivesUp() {
        let (r, e) = runner(level: 3)
        e.drift = .drifted
        for s in 0..<3 { r.watchdogTick(brightness: 0, now: t0 + Double(s)) }
        #expect(e.calls == [.drift, .apply(3), .drift, .apply(3), .drift, .apply(3)])
        r.watchdogTick(brightness: 0, now: t0 + 3)
        #expect(e.calls.suffix(4) == [.drift, .restore, .stopWatchdog, .hud(.resetByOtherApp)])
        #expect(r.machine.level == 0)
    }

    /// Finding: an unreadable gamma table in the watchdog is a gamma failure (spec §7), not silence.
    @Test func watchdogUnreadableGammaFails() {
        let (r, e) = runner(level: 3)
        e.drift = .unreadable
        r.watchdogTick(brightness: 0, now: t0)
        #expect(e.calls == [.drift, .restore, .stopWatchdog, .hud(.cannotDim)])
        #expect(r.machine.level == 0)
    }

    @Test func watchdogInSyncDoesNothing() {
        let (r, e) = runner(level: 3)
        r.watchdogTick(brightness: 0, now: t0)
        #expect(e.calls == [.drift])
        #expect(r.machine.level == 3)
    }
}
