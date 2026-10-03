import CoreAudio
import Testing
@testable import MixerCore

/// Owns an AudioBufferList. `layout` is channels per buffer: [2] interleaved stereo, [1, 1] planar stereo.
final class TestBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private let frames: Int

    init(layout: [Int], frames: Int, fill: (_ channel: Int, _ frame: Int) -> Float = { _, _ in 0 }) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        var firstChannel = 0
        for (index, channels) in layout.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(channels * frames, 1))
            for frame in 0..<frames {
                for channel in 0..<channels {
                    data[frame * channels + channel] = fill(firstChannel + channel, frame)
                }
            }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: data)
            firstChannel += channels
        }
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    func channel(_ index: Int) -> [Float] {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                return (0..<frames).map { data[$0 * channels + remaining] }
            }
            remaining -= channels
        }
        return []
    }
}

struct RendererTests {
    private func run(_ input: TestBuffers, _ output: TestBuffers, current: Float, target: Float, step: Float = 1) -> Float {
        var gain = current
        Renderer.process(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer,
                         current: &gain, target: target, step: step)
        return gain
    }

    @Test func unityGainCopies() {
        let input = TestBuffers(layout: [2], frames: 4) { channel, frame in channel == 0 ? Float(frame + 1) : -Float(frame + 1) }
        let output = TestBuffers(layout: [2], frames: 4)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 2, 3, 4])
        #expect(output.channel(1) == [-1, -2, -3, -4])
    }

    @Test func scalesByGain() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 0.25, target: 0.25)
        #expect(output.channel(0) == [0.25, 0.25])
        #expect(output.channel(1) == [0.25, 0.25])
    }

    @Test func rampsTowardTarget() {
        let input = TestBuffers(layout: [2], frames: 5) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 5)
        let end = run(input, output, current: 1, target: 0, step: 0.25)
        #expect(output.channel(0) == [0.75, 0.5, 0.25, 0, 0])
        #expect(end == 0)
    }

    @Test func rampsUpWithoutOvershoot() {
        let input = TestBuffers(layout: [2], frames: 3) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 3)
        let end = run(input, output, current: 0, target: 0.5, step: 0.375)
        #expect(output.channel(0) == [0.375, 0.5, 0.5])
        #expect(end == 0.5)
    }

    @Test func monoOutputAveragesChannels() {
        let input = TestBuffers(layout: [2], frames: 2) { channel, _ in channel == 0 ? 1 : 0 }
        let output = TestBuffers(layout: [1], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [0.5, 0.5])
    }

    @Test func monoInputFeedsBothOutputs() {
        let input = TestBuffers(layout: [1], frames: 2) { _, _ in 0.5 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [0.5, 0.5])
        #expect(output.channel(1) == [0.5, 0.5])
    }

    @Test func planarInputToInterleavedOutput() {
        let input = TestBuffers(layout: [1, 1], frames: 2) { channel, _ in channel == 0 ? 1 : 2 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1])
        #expect(output.channel(1) == [2, 2])
    }

    @Test func outputLongerThanInputIsSilentAfterInputEnds() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 4) { _, _ in 9 }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1, 0, 0])
        #expect(output.channel(1) == [1, 1, 0, 0])
    }

    @Test func extraOutputChannelsAreSilent() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [4], frames: 2) { _, _ in 9 }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1])
        #expect(output.channel(2) == [0, 0])
        #expect(output.channel(3) == [0, 0])
    }

    /// An aggregate device lists the output device's own inputs (a headset mic) before the tap.
    @Test func readsTapFromLastTwoInputChannels() {
        let input = TestBuffers(layout: [2, 2], frames: 2) { channel, _ in Float(channel + 1) }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [3, 3])
        #expect(output.channel(1) == [4, 4])
    }

    @Test func readsTapAfterMonoDeviceInput() {
        let input = TestBuffers(layout: [1, 2], frames: 2) { channel, _ in Float(channel + 1) }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [2, 2])
        #expect(output.channel(1) == [3, 3])
    }

    @Test func interleavedInputToPlanarOutput() {
        let input = TestBuffers(layout: [2], frames: 2) { channel, _ in channel == 0 ? 1 : 2 }
        let output = TestBuffers(layout: [1, 1], frames: 2) { _, _ in 9 }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1])
        #expect(output.channel(1) == [2, 2])
    }

    @Test func zeroChannelBuffersAreSkipped() {
        let input = TestBuffers(layout: [0, 2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [0, 2], frames: 2) { _, _ in 9 }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1])
        #expect(output.channel(1) == [1, 1])
    }

    @Test func bufferWithoutDataIsSkipped() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [2, 2], frames: 2) { _, _ in 9 }
        let detached = output.list[0].mData
        output.list[0].mData = nil
        defer { output.list[0].mData = detached }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(2) == [1, 1])
        #expect(output.channel(3) == [1, 1])
    }

    @Test func boostAmplifiesQuietSamples() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 0.25 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 2, target: 2)
        #expect(output.channel(0) == [0.5, 0.5])
    }

    @Test func boostNeverExceedsFullScale() {
        let input = TestBuffers(layout: [2], frames: 2) { channel, _ in channel == 0 ? 1 : -1 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 2.25, target: 2.25)
        #expect(output.channel(0).allSatisfy { $0 > 0.8 && $0 < 1 })
        #expect(output.channel(1).allSatisfy { $0 < -0.8 && $0 > -1 })
    }

    @Test func unityGainIsNotLimited() {
        let input = TestBuffers(layout: [2], frames: 1) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 1)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1])
    }

    @Test func emptyInputLeavesSilence() {
        let input = TestBuffers(layout: [2], frames: 0)
        let output = TestBuffers(layout: [2], frames: 2) { _, _ in 9 }
        let end = run(input, output, current: 0.3, target: 1, step: 0.1)
        #expect(output.channel(0) == [0, 0])
        #expect(end == 0.3)
    }
}
