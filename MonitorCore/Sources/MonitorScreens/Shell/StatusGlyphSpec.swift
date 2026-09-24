import Foundation
import MonitorModel

/// What the menu bar glyph shows for an `AlertState` (DESIGN §4.3), independent of drawing.
/// `StatusItemController` (App) draws it; W3's `StatusGlyphRenderer` implements the same table.
public struct StatusGlyphSpec: Hashable, Sendable {
    public enum Ink: Int, Equatable, Sendable, Comparable {
        case label, elevated, critical
        public static func < (a: Ink, b: Ink) -> Bool { a.rawValue < b.rawValue }
        init(_ level: AlertLevel) {
            switch level {
            case .calm: self = .label
            case .elevated: self = .elevated
            case .critical: self = .critical
            }
        }
    }

    /// One ink per arc in `IconArc.allCases` order (cpu, gpu, memory, network, thermals = arcs 0…4).
    public var arcs: [Ink]
    public var dot: Ink
    /// viewBox units (18-unit box): 1.4 calm, 1.6 elevated, 2.1 critical; the pulse grows it to 2.9.
    public var dotRadius: Double
    /// Calm (and paused) → template image that follows the menu bar tint.
    public var isTemplate: Bool
    /// Whole-glyph alpha: 0.5 while paused.
    public var alpha: Double
    /// Alpha of the stressed (non-label) arcs only: the critical pulse goes 1 → 0.45 → 1.
    public var stressedAlpha: Double

    public static func make(_ state: AlertState, pulse: StatusPulse.Frame? = nil) -> StatusGlyphSpec {
        if state.paused {                                            // alerts suppressed while paused
            return StatusGlyphSpec(arcs: Array(repeating: .label, count: 5), dot: .label, dotRadius: 1.4,
                                   isTemplate: true, alpha: 0.5, stressedAlpha: 1)
        }
        let arcs = IconArc.allCases.map { Ink(state.arcs[$0] ?? .calm) }
        let dot = max(arcs.max() ?? .label, Ink(state.level))
        var r = switch dot {
        case .label: 1.4
        case .elevated: 1.6
        case .critical: 2.1
        }
        var stressedAlpha = 1.0
        if let pulse, dot == .critical {
            r = pulse.dotRadius
            stressedAlpha = pulse.arcAlpha
        }
        return StatusGlyphSpec(arcs: arcs, dot: dot, dotRadius: r, isTemplate: dot == .label, alpha: 1,
                               stressedAlpha: stressedAlpha)
    }
}

/// The critical pulse (DESIGN §4.3): 600 ms ease-in-out, 18 frames at 30 fps; dot r 2.1 → 2.9 → 2.1,
/// stressed arc alpha 1 → 0.45 → 1. Runs once per `pulseToken` change into critical, never with Reduce Motion.
public enum StatusPulse {
    public struct Frame: Equatable, Sendable {
        public var dotRadius: Double
        public var arcAlpha: Double
    }

    public static let frameCount = 18
    public static let frameInterval: Duration = .milliseconds(1000 / 30)

    /// Frame `i` of `0..<frameCount`; the first and last are the static critical look.
    public static func frame(_ i: Int) -> Frame {
        let t = Double(min(max(i, 0), frameCount - 1)) / Double(frameCount - 1)
        let v = 0.5 - 0.5 * cos(2 * .pi * t)                 // 0 → 1 → 0, eased at both ends and the peak
        return Frame(dotRadius: 2.1 + 0.8 * v, arcAlpha: 1 - 0.55 * v)
    }

    public static var frames: [Frame] { (0..<frameCount).map(frame) }

    /// Pulse when the token advanced while the state is critical and not paused.
    public static func shouldPulse(previousToken: Int?, state: AlertState, reduceMotion: Bool) -> Bool {
        guard let previousToken, !reduceMotion, !state.paused, state.level == .critical else { return false }
        return state.pulseToken != previousToken
    }
}

/// Popover/status-item status line (DESIGN §3.2 alert table, §3.15 paused).
public enum StatusLine {
    public static func text(for state: AlertState) -> String {
        if state.paused { return "Sampling paused" }
        guard let top = state.active.first else { return "All systems nominal" }
        let more = state.active.count > 1 ? " · +\(state.active.count - 1)" : ""
        return describe(top) + more
    }

    static func describe(_ a: ActiveAlert) -> String {
        switch a.kind {
        case .thermalPressure(let p):
            let word: String = switch p {
            case .nominal: "Nominal"
            case .fair: "Fair"
            case .serious: "Serious"
            case .critical: "Critical"
            }
            return "Thermal pressure: " + word
        case .memoryPressure(let m):
            let word: String = switch m {
            case .normal: "Normal"
            case .warning: "Warning"
            case .critical: "Critical"
            }
            return "Memory pressure: " + word
        case .runawayApp(let key, _):
            return "Runaway app: " + (a.culprit?.displayName ?? key.id)
        }
    }
}
