import Foundation

/// Deterministic LCG matching the design artboards' demo generator bit-for-bit
/// (`docs/design/render` inline scripts: `__rng`/`__mk`/`__step`), so `.calm` reproduces the
/// reference renders' numbers. `state &* 1_664_525 &+ 1_013_904_223` on `UInt32` wraps modulo 2^32,
/// exactly like the artboards' `Math.imul(s, 1664525) + 1013904223) >>> 0`.
struct DemoLCG {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / 4_294_967_296.0
    }
}

/// One noisy series: mean-reverts toward `base` with volatility `vol`, occasional larger jumps
/// (5% chance per step), clamped to `[min, max]`. Mirrors the artboards' `__mk`/`__step` exactly,
/// including RNG draw order, so the same seed produces the same trajectory.
struct DemoSeries {
    let base, vol, min, max: Double
    private var rng: DemoLCG
    private(set) var value: Double

    /// `warmup` steps run immediately (the artboards pre-fill `n` samples on mount before the first
    /// render), so `value` after `init` is what the reference PNG shows at "tick 0".
    init(seed: UInt32, base: Double, vol: Double, min: Double, max: Double, warmup: Int = 60) {
        self.rng = DemoLCG(seed: seed)
        self.base = base
        self.vol = vol
        self.min = min
        self.max = max
        self.value = base
        for _ in 0..<warmup { step() }
    }

    @discardableResult
    mutating func step() -> Double {
        value += (rng.next() - 0.5) * vol + (base - value) * 0.12
        if rng.next() < 0.05 {
            value += vol * 1.6 * (rng.next() - 0.35)
        }
        if value < min { value = min }
        if value > max { value = max }
        return value
    }

    /// The value `ticks` steps beyond the warmed-up state (0 = the warmed-up value itself).
    /// Pure/deterministic: replays from the warmed-up state, so equal `ticks` always yields equal output.
    func value(afterTicks ticks: Int) -> Double {
        guard ticks > 0 else { return value }
        var copy = self
        for _ in 0..<ticks { copy.step() }
        return copy.value
    }
}
