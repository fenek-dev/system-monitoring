import Foundation

/// Extra Dim curve (spec §4): geometric in luminance, `L(n) = 0.10^(n/8)` — a constant ≈ 25 % drop per step down
/// to a 10 % floor. Gamma tables are display-encoded, so the table multiplier is `m(n) = L(n)^(1/2.2)`.
public enum ExtraDimCurve {
    public static let steps = 8
    /// Luminance at `steps`.
    public static let floor = 0.10
    public static let displayGamma = 2.2

    /// Luminance factor at `level` (clamped to 0…steps).
    public static func luminance(_ level: Int) -> Double {
        pow(floor, Double(clamp(level)) / Double(steps))
    }

    /// Per-entry gamma table multiplier at `level` (clamped to 0…steps). `multiplier(0) == 1` exactly.
    public static func multiplier(_ level: Int) -> Double {
        clamp(level) == 0 ? 1 : pow(luminance(level), 1 / displayGamma)
    }

    static func clamp(_ level: Int) -> Int { min(max(level, 0), steps) }
}
