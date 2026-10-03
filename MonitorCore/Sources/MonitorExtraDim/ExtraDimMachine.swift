import Foundation

/// Extra Dim state + transitions (spec §3 "Machine", §5). Pure: the app's `ExtraDimService` feeds inputs (including
/// `now` for the fight guard) and executes the returned actions; nothing here touches AppKit, CoreGraphics or time.
public struct ExtraDimMachine: Equatable, Sendable {
    public enum Key: Equatable, Sendable { case down, up }

    public enum HUD: Equatable, Sendable {
        case level(Int)
        case resetByOtherApp
        case cannotDim
    }

    public enum Input: Equatable, Sendable {
        case setEnabled(Bool)
        /// A brightness key-down. `brightness` is read in the tap callback; nil = the read failed.
        case key(Key, brightness: Float?)
        /// Watchdog tick (nil = unreadable: the tick is skipped).
        case brightness(Float?)
        /// The watchdog found the live table ≠ `base × m(level)`.
        case gammaDrift(at: Date)
        /// Wake, screens-wake, unlock, or screen params changed with the built-in display still present.
        case reapply
        case builtinDisplayGone
        /// Capturing or writing the gamma table failed (spec §7): back to level 0 with the `.cannotDim` HUD.
        case gammaFailed
    }

    public enum Action: Equatable, Sendable {
        case captureBase
        case applyGamma(level: Int)
        case restoreGamma
        case showHUD(HUD)
        case startWatchdog
        case stopWatchdog
    }

    public struct Step: Equatable, Sendable {
        /// Swallow the key event (the system never sees it).
        public var consumeKey: Bool
        public var actions: [Action]

        public init(consumeKey: Bool = false, actions: [Action] = []) {
            self.consumeKey = consumeKey
            self.actions = actions
        }
    }

    public static let steps = ExtraDimCurve.steps
    /// Brightness at or below this is the system minimum.
    public static let minBrightness: Float = 0.001
    /// Fight guard: this many drifts within `fightWindow` give up (spec §5.5).
    public static let fightLimit = 4
    public static let fightWindow: TimeInterval = 10

    public private(set) var enabled: Bool
    public private(set) var level: Int
    public private(set) var driftTimes: [Date]

    public init(enabled: Bool = false, level: Int = 0, driftTimes: [Date] = []) {
        self.enabled = enabled
        self.level = min(max(level, 0), Self.steps)
        self.driftTimes = driftTimes
    }

    public static func atMin(_ brightness: Float?) -> Bool {
        guard let brightness else { return false }
        return brightness <= minBrightness
    }

    public mutating func handle(_ input: Input) -> Step {
        switch input {
        case .setEnabled(let on):
            enabled = on
            return on ? Step() : Step(actions: clear())

        case .key(let key, let brightness):
            // Stale dim: the backlight was raised elsewhere — clear first, then handle as level 0 (passes through).
            let stale = staleClear(brightness)
            guard enabled else { return Step(actions: stale) }
            var step = handleKey(key, atMin: Self.atMin(brightness))
            step.actions = stale + step.actions
            return step

        case .brightness(let brightness):
            return Step(actions: staleClear(brightness))

        case .gammaDrift(let now):
            guard level > 0 else { return Step() }
            driftTimes = driftTimes.filter { now.timeIntervalSince($0) < Self.fightWindow } + [now]
            if driftTimes.count >= Self.fightLimit {
                return Step(actions: clear() + [.showHUD(.resetByOtherApp)])
            }
            return Step(actions: [.applyGamma(level: level)])

        case .reapply:
            return level > 0 ? Step(actions: [.applyGamma(level: level)]) : Step()

        case .builtinDisplayGone:
            return Step(actions: clear())

        case .gammaFailed:
            return Step(actions: clear(force: true) + [.showHUD(.cannotDim)])
        }
    }

    private mutating func handleKey(_ key: Key, atMin: Bool) -> Step {
        switch key {
        case .down:
            guard atMin else { return Step() }
            switch level {
            case 0:
                level = 1
                return Step(consumeKey: true,
                            actions: [.captureBase, .applyGamma(level: 1), .showHUD(.level(1)), .startWatchdog])
            case Self.steps:
                return Step(consumeKey: true, actions: [.showHUD(.level(level))])
            default:
                level += 1
                return Step(consumeKey: true, actions: [.applyGamma(level: level), .showHUD(.level(level))])
            }
        case .up:
            switch level {
            case 0:
                return Step()
            case 1:
                level = 0
                driftTimes = []
                return Step(consumeKey: true, actions: [.restoreGamma, .showHUD(.level(0)), .stopWatchdog])
            default:
                level -= 1
                return Step(consumeKey: true, actions: [.applyGamma(level: level), .showHUD(.level(level))])
            }
        }
    }

    /// Readable brightness above min while dimmed → clear (no HUD). Unreadable or at min → nothing.
    private mutating func staleClear(_ brightness: Float?) -> [Action] {
        guard level > 0, brightness != nil, !Self.atMin(brightness) else { return [] }
        return clear()
    }

    /// Back to level 0: restore + stop the watchdog. `force` also emits them at level 0 (a failed 0→1 capture).
    private mutating func clear(force: Bool = false) -> [Action] {
        let wasDimmed = level > 0
        level = 0
        driftTimes = []
        return wasDimmed || force ? [.restoreGamma, .stopWatchdog] : []
    }
}
