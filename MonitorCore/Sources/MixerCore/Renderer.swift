import CoreAudio

public enum Renderer {
    private typealias Channel = (samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int)

    /// Copies the last two input channels to the first two output channels, scaled by a gain
    /// that moves toward `target` by at most `step` per frame. Real-time safe.
    public static func process(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        current: inout Float,
        target: Float,
        step: Float
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // An aggregate device lists its sub-device's own inputs (a headset mic) before the tap,
        // so the stereo tap is the last two input channels, not the first two.
        let tapStart = max(channelCount(inputs) - 2, 0)
        guard let inLeft = channel(inputs, tapStart), let outLeft = channel(outputs, 0) else { return }
        let inRight = channel(inputs, tapStart + 1) ?? inLeft
        let outRight = channel(outputs, 1)
        let frames = min(inLeft.frames, inRight.frames, outLeft.frames, outRight?.frames ?? .max)

        var gain = current
        for frame in 0..<frames {
            if gain < target {
                gain = min(gain + step, target)
            } else if gain > target {
                gain = max(gain - step, target)
            }
            var left = inLeft.samples[frame * inLeft.stride] * gain
            var right = inRight.samples[frame * inRight.stride] * gain
            // Only boosted audio can exceed full scale; at or below unity the samples pass untouched.
            if gain > 1 {
                left = Gain.limit(left)
                right = Gain.limit(right)
            }
            if let outRight {
                outLeft.samples[frame * outLeft.stride] = left
                outRight.samples[frame * outRight.stride] = right
            } else {
                outLeft.samples[frame * outLeft.stride] = (left + right) * 0.5
            }
        }
        current = gain
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in list where buffer.mData != nil {
            count += Int(buffer.mNumberChannels)
        }
        return count
    }

    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> Channel? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            if remaining < channels {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (data.assumingMemoryBound(to: Float.self) + remaining, channels, frames)
            }
            remaining -= channels
        }
        return nil
    }
}
