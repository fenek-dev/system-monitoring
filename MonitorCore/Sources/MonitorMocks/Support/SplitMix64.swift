import Foundation

/// A non-sequential hash-based PRNG: `value(seed:index:)` maps a `(seed, index)` pair directly to a
/// `[0, 1)` double with no replay from a starting state, so any point in a 30-day history is O(1) to
/// evaluate (`MockHistoryProvider`'s <20 ms/query budget rules out replaying a sequential generator over
/// millions of prior points). Standard SplitMix64 mixing (Vigna, 2015).
enum SplitMix64 {
    static func hash(_ seed: UInt64, _ index: Int) -> UInt64 {
        var z = seed &+ UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        z = z &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    static func unit(_ seed: UInt64, _ index: Int) -> Double {
        Double(hash(seed, index) >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 53 bits of precision
    }

    /// Uniform in `[-1, 1)`.
    static func signed(_ seed: UInt64, _ index: Int) -> Double {
        unit(seed, index) * 2 - 1
    }
}
