import Testing
@testable import MonitorEngine

@Suite struct RateCalculatorTests {
    @Test func firstSightIsNil() {
        var r = RateCalculator<String>()
        #expect(r.rate(for: "a", counter: 100, capturedNs: 1_000_000_000) == nil)
        #expect(r.count == 1)
    }

    @Test func rateIsDeltaOverCapturedInterval() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 100, capturedNs: 1_000_000_000)
        #expect(r.rate(for: "a", counter: 300, capturedNs: 3_000_000_000) == 100)
        let d = r.delta(for: "a", counter: 400, capturedNs: 3_500_000_000)
        #expect(d?.delta == 100)
        #expect(d?.seconds == 0.5)
    }

    @Test func sameCapturedNsReturnsPreviousResult() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 100, capturedNs: 1_000_000_000)
        #expect(r.rate(for: "a", counter: 200, capturedNs: 2_000_000_000) == 100)
        // cached reading: same capturedNs → same rate, not 0 and not a new delta
        #expect(r.rate(for: "a", counter: 200, capturedNs: 2_000_000_000) == 100)
        #expect(r.rate(for: "a", counter: 200, capturedNs: 2_000_000_000) == 100)
        // next fresh reading is timed from the last real baseline
        #expect(r.rate(for: "a", counter: 250, capturedNs: 3_000_000_000) == 50)
    }

    @Test func sameCapturedNsBeforeAnyRateIsNil() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 100, capturedNs: 1_000_000_000)
        #expect(r.rate(for: "a", counter: 100, capturedNs: 1_000_000_000) == nil)
    }

    @Test func counterDecreaseIsNilAndRebaselines() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 1_000, capturedNs: 1_000_000_000)
        #expect(r.rate(for: "a", counter: 10, capturedNs: 2_000_000_000) == nil)      // reset: no wrap
        #expect(r.rate(for: "a", counter: 10, capturedNs: 2_000_000_000) == nil)      // cached after reset: still nil
        #expect(r.rate(for: "a", counter: 30, capturedNs: 3_000_000_000) == 20)
    }

    @Test func capturedNsGoingBackRebaselines() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 100, capturedNs: 5_000_000_000)
        #expect(r.rate(for: "a", counter: 200, capturedNs: 4_000_000_000) == nil)
        #expect(r.rate(for: "a", counter: 300, capturedNs: 5_000_000_000) == 100)
    }

    @Test func unchangedCounterIsZeroRate() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 100, capturedNs: 1_000_000_000)
        #expect(r.rate(for: "a", counter: 100, capturedNs: 2_000_000_000) == 0)
    }

    @Test func pruneDropsDeadKeys() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 1, capturedNs: 1)
        _ = r.rate(for: "b", counter: 1, capturedNs: 1)
        r.prune(keeping: ["b"])
        #expect(r.count == 1)
        #expect(r.rate(for: "a", counter: 5, capturedNs: 1_000_000_001) == nil)      // a was forgotten
        #expect(r.rate(for: "b", counter: 5, capturedNs: 1_000_000_001) == 4)
    }

    @Test func resetForgetsEverything() {
        var r = RateCalculator<Int>()
        _ = r.rate(for: 1, counter: 1, capturedNs: 1)
        r.reset()
        #expect(r.count == 0)
        #expect(r.rate(for: 1, counter: 9, capturedNs: 1_000_000_001) == nil)
    }

    @Test func keysAreIndependent() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: 0, capturedNs: 0)
        _ = r.rate(for: "b", counter: 0, capturedNs: 0)
        #expect(r.rate(for: "a", counter: 10, capturedNs: 1_000_000_000) == 10)
        #expect(r.rate(for: "b", counter: 20, capturedNs: 2_000_000_000) == 10)
    }

    @Test func hugeCounterNoOverflow() {
        var r = RateCalculator<String>()
        _ = r.rate(for: "a", counter: UInt64.max - 10, capturedNs: 0)
        #expect(r.delta(for: "a", counter: UInt64.max, capturedNs: 1_000_000_000)?.delta == 10)
        #expect(r.rate(for: "a", counter: 3, capturedNs: 2_000_000_000) == nil)   // wrapped → reset, not 2^64-ish
    }
}
