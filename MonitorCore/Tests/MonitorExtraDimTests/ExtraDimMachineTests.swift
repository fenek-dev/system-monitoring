import Foundation
import Testing
@testable import MonitorExtraDim

typealias M = ExtraDimMachine
private let atMin: Float = 0
private let aboveMin: Float = 0.4

private func machine(level: Int = 0, enabled: Bool = true) -> M {
    M(enabled: enabled, level: level)
}

private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + s) }

@Suite struct ExtraDimMachineTests {
    @Test func downAtMinStepsZeroToEight() {
        var m = machine()
        let expected: [[M.Action]] = (1...8).map { n in
            n == 1 ? [.captureBase, .applyGamma(level: 1), .showHUD(.level(1)), .startWatchdog]
                   : [.applyGamma(level: n), .showHUD(.level(n))]
        }
        for (i, actions) in expected.enumerated() {
            let step = m.handle(.key(.down, brightness: atMin))
            #expect(step == M.Step(consumeKey: true, actions: actions), "press \(i + 1)")
            #expect(m.level == i + 1)
        }
    }

    @Test func downAtLevelEightReshowsHUDOnly() {
        var m = machine(level: 8)
        #expect(m.handle(.key(.down, brightness: atMin)) == M.Step(consumeKey: true, actions: [.showHUD(.level(8))]))
        #expect(m.level == 8)
    }

    @Test func upStepsBackThenPassesThrough() {
        var m = machine(level: 3)
        #expect(m.handle(.key(.up, brightness: atMin))
            == M.Step(consumeKey: true, actions: [.applyGamma(level: 2), .showHUD(.level(2))]))
        #expect(m.handle(.key(.up, brightness: atMin))
            == M.Step(consumeKey: true, actions: [.applyGamma(level: 1), .showHUD(.level(1))]))
        #expect(m.handle(.key(.up, brightness: atMin))
            == M.Step(consumeKey: true, actions: [.restoreGamma, .showHUD(.level(0)), .stopWatchdog]))
        #expect(m.level == 0)
        #expect(m.handle(.key(.up, brightness: atMin)) == M.Step())
    }

    @Test(arguments: [M.Key.down, .up], [Float?.some(aboveMin), nil])
    func keysPassThroughAboveMinOrUnreadable(key: M.Key, brightness: Float?) {
        var m = machine()
        #expect(m.handle(.key(key, brightness: brightness)) == M.Step())
        #expect(m.level == 0)
    }

    @Test func staleDimDownClearsAndPassesThrough() {
        var m = machine(level: 3)
        #expect(m.handle(.key(.down, brightness: aboveMin)) == M.Step(actions: [.restoreGamma, .stopWatchdog]))
        #expect(m.level == 0)
    }

    @Test func staleDimUpClearsAndPassesThrough() {
        var m = machine(level: 3)
        #expect(m.handle(.key(.up, brightness: aboveMin)) == M.Step(actions: [.restoreGamma, .stopWatchdog]))
        #expect(m.level == 0)
    }

    @Test func unreadableBrightnessKeepsDimOnUp() {
        // Up never needs "at min": an unreadable read still steps back (it is not stale-cleared).
        var m = machine(level: 3)
        #expect(m.handle(.key(.up, brightness: nil))
            == M.Step(consumeKey: true, actions: [.applyGamma(level: 2), .showHUD(.level(2))]))
    }

    @Test(arguments: [M.Key.down, .up], [Float?.some(atMin), .some(aboveMin), nil])
    func disabledPassesEveryKey(key: M.Key, brightness: Float?) {
        var m = machine(enabled: false)
        #expect(m.handle(.key(key, brightness: brightness)) == M.Step())
        #expect(m.level == 0)
    }

    @Test func watchdogBrightnessAboveMinClears() {
        var m = machine(level: 5)
        #expect(m.handle(.brightness(atMin)) == M.Step())
        #expect(m.handle(.brightness(nil)) == M.Step())
        #expect(m.level == 5)
        #expect(m.handle(.brightness(aboveMin)) == M.Step(actions: [.restoreGamma, .stopWatchdog]))
        #expect(m.level == 0)
    }

    @Test func reapplyReappliesWithoutCapture() {
        var m = machine(level: 4)
        #expect(m.handle(.reapply) == M.Step(actions: [.applyGamma(level: 4)]))
        #expect(m.level == 4)
        var idle = machine()
        #expect(idle.handle(.reapply) == M.Step())
    }

    @Test func builtinDisplayGoneClears() {
        var m = machine(level: 6)
        #expect(m.handle(.builtinDisplayGone) == M.Step(actions: [.restoreGamma, .stopWatchdog]))
        #expect(m.level == 0)
        #expect(m.handle(.builtinDisplayGone) == M.Step())
    }

    @Test func fightGuardGivesUpOnFourthDriftInWindow() {
        var m = machine(level: 2)
        for s in [0.0, 3, 6] {
            #expect(m.handle(.gammaDrift(at: t(s))) == M.Step(actions: [.applyGamma(level: 2)]))
        }
        #expect(m.handle(.gammaDrift(at: t(9)))
            == M.Step(actions: [.restoreGamma, .stopWatchdog, .showHUD(.resetByOtherApp)]))
        #expect(m.level == 0)
        #expect(m.driftTimes.isEmpty)
    }

    @Test func driftsOutsideWindowDontCount() {
        var m = machine(level: 2)
        for s in [0.0, 5, 10, 15, 20, 25] {   // never 4 within 10 s
            #expect(m.handle(.gammaDrift(at: t(s))) == M.Step(actions: [.applyGamma(level: 2)]), "drift at \(s)")
        }
        #expect(m.level == 2)
    }

    @Test func driftAtLevelZeroIgnored() {
        var m = machine()
        #expect(m.handle(.gammaDrift(at: t(0))) == M.Step())
        #expect(m.driftTimes.isEmpty)
    }

    @Test func setEnabledFalseClears() {
        var m = machine(level: 3)
        #expect(m.handle(.setEnabled(false)) == M.Step(actions: [.restoreGamma, .stopWatchdog]))
        #expect(m.level == 0)
        #expect(!m.enabled)
        #expect(m.handle(.key(.down, brightness: atMin)) == M.Step())
    }

    @Test func setEnabledTrueHasNoActions() {
        var m = machine(enabled: false)
        #expect(m.handle(.setEnabled(true)) == M.Step())
        #expect(m.enabled)
    }

    @Test func gammaFailureReturnsToZeroWithHUD() {
        var m = machine(level: 1)
        #expect(m.handle(.gammaFailed) == M.Step(actions: [.restoreGamma, .stopWatchdog, .showHUD(.cannotDim)]))
        #expect(m.level == 0)
    }
}
