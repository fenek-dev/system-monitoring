import Darwin

/// Collects small scroll deltas and releases them as whole-percent steps.
public struct StepAccumulator {
    private var pending: Float = 0

    public init() {}

    /// Returns the whole-percent part of everything added so far and keeps the remainder.
    public mutating func add(_ delta: Float) -> Float {
        pending += delta
        let whole = (pending * 100).rounded(.towardZero) / 100
        pending -= whole
        return whole
    }

    public mutating func reset() {
        pending = 0
    }
}

public enum Gain {
    /// Slider position to linear gain. Squared so the slider feels even to the ear.
    public static func curve(_ position: Float) -> Float {
        let clamped = position.isNaN ? 1 : min(max(position, 0), AppVolume.maxVolume)
        return clamped * clamped
    }

    public static func gain(for volume: AppVolume) -> Float {
        volume.muted ? 0 : curve(volume.volume)
    }

    /// Per-frame gain change so a full 0...1 sweep takes `seconds`.
    public static func rampStep(sampleRate: Double, seconds: Double = 0.010) -> Float {
        sampleRate > 0 ? Float(1 / (sampleRate * seconds)) : 1
    }

    /// Moves a slider position by `delta` and lands on a whole percent, so repeated key presses
    /// do not drift.
    public static func stepped(_ position: Float, by delta: Float) -> Float {
        let percent = ((position + delta) * 100).rounded()
        return min(max(percent / 100, 0), AppVolume.maxVolume)
    }

    /// Soft limiter for boosted audio: transparent up to 0.8 of full scale, then bends so the
    /// result never reaches 1. Real-time safe.
    @inline(__always)
    public static func limit(_ sample: Float) -> Float {
        let knee: Float = 0.8
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let limited = knee + (1 - knee) * tanhf((magnitude - knee) / (1 - knee))
        return sample < 0 ? -limited : limited
    }
}
