import Testing
@testable import MixerCore

struct GainTests {
    @Test func curveIsSquared() {
        #expect(Gain.curve(0) == 0)
        #expect(Gain.curve(0.5) == 0.25)
        #expect(Gain.curve(1) == 1)
    }

    @Test func curveClamps() {
        #expect(Gain.curve(2) == 2.25)
        #expect(Gain.curve(-1) == 0)
        #expect(Gain.curve(.nan) == 1)
    }

    @Test func boostCurveGoesAboveUnity() {
        #expect(Gain.curve(1.5) == 2.25)
    }

    @Test func steppingLandsOnWholePercents() {
        #expect(Gain.stepped(0.5, by: 0.05) == 0.55)
        #expect(Gain.stepped(0.55, by: -0.05) == 0.5)
        #expect(Gain.stepped(0.999, by: 0.01) == 1.01)
        #expect(Gain.stepped(1.48, by: 0.05) == 1.5)
        #expect(Gain.stepped(0.02, by: -0.05) == 0)
    }

    /// Scroll deltas are tiny; whole-percent steps keep the volume able to land on exactly 100%.
    @Test func accumulatorReleasesWholePercentsOnly() {
        var accumulator = StepAccumulator()
        #expect(accumulator.add(0.004) == 0)
        #expect(accumulator.add(0.004) == 0)
        #expect(accumulator.add(0.004) == 0.01)
        #expect(accumulator.add(0.03) == 0.03)
    }

    @Test func accumulatorWorksDownward() {
        var accumulator = StepAccumulator()
        #expect(accumulator.add(-0.006) == 0)
        #expect(accumulator.add(-0.006) == -0.01)
    }

    @Test func accumulatorResetDropsPartialStep() {
        var accumulator = StepAccumulator()
        _ = accumulator.add(0.009)
        accumulator.reset()
        #expect(accumulator.add(0.002) == 0)
    }

    @Test func limiterLeavesQuietSamplesAndBoundsLoudOnes() {
        #expect(Gain.limit(0.5) == 0.5)
        #expect(Gain.limit(-0.8) == -0.8)
        #expect(Gain.limit(2.25) < 1)
        #expect(Gain.limit(2.25) > 0.8)
        #expect(Gain.limit(-2.25) > -1)
        #expect(Gain.limit(1.0) < Gain.limit(1.5))
    }

    @Test func muteForcesZero() {
        #expect(Gain.gain(for: AppVolume(volume: 0.5, muted: true)) == 0)
        #expect(Gain.gain(for: AppVolume(volume: 0.5, muted: false)) == 0.25)
    }

    @Test func rampStepCoversFullRangeInTenMilliseconds() {
        #expect(abs(Gain.rampStep(sampleRate: 48000) - 1.0 / 480.0) < 1e-7)
        #expect(Gain.rampStep(sampleRate: 0) == 1)
    }
}
