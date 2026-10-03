import CoreAudio
import Foundation
import Synchronization

/// Shared with the IO thread. `target` is written from the main thread; the rest is IO-thread only.
private final class RenderState: @unchecked Sendable {
    let target: Atomic<UInt32>
    var current: Float
    var step: Float = 1

    init(gain: Float) {
        target = Atomic(gain.bitPattern)
        // The app was at full volume until now, so ramp down from there instead of jumping.
        current = 1
    }
}

/// Mutes an app's own output and replays it on the default output device with a gain applied.
public final class TapVolumeController: VolumeControlling {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let state: RenderState

    public init(objectIDs: [AudioObjectID], gain: Float) throws {
        state = RenderState(gain: gain)
        do {
            try start(objectIDs: objectIDs)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    public func setGain(_ gain: Float) {
        state.target.store(gain.bitPattern, ordering: .relaxed)
    }

    public func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func start(objectIDs: [AudioObjectID]) throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tap.uuid = UUID()
        tap.muteBehavior = .mutedWhenTapped
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

        let output = try AudioObjectID.system.readValue(
            kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        let outputUID = try output.readString(kAudioDevicePropertyDeviceUID)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")

        let sampleRate = (try? aggregateID.readValue(kAudioDevicePropertyNominalSampleRate, initial: Float64(48000))) ?? 48000
        state.step = Gain.rampStep(sampleRate: sampleRate)

        let state = self.state
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            let target = Float(bitPattern: state.target.load(ordering: .relaxed))
            Renderer.process(input: input, output: output, current: &state.current, target: target, step: state.step)
        }, "create IO proc")
        disableDeviceInputs(of: output)
        try check(AudioDeviceStart(aggregateID, ioProcID), "start device")
    }

    /// The aggregate also exposes the output device's own inputs (a headset mic). Leaving them on
    /// opens the mic, which drops a Bluetooth headset to call quality. Turns off every input
    /// stream except the tap's; best effort, since audio still works if this is refused.
    private func disableDeviceInputs(of output: AudioObjectID) {
        guard let ioProcID else { return }
        let deviceInputs = output.inputStreamCount()
        let total = aggregateID.inputStreamCount()
        // The device's streams come before the tap's.
        guard deviceInputs > 0, total > deviceInputs else { return }

        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = flagsOffset + total * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: max(size, MemoryLayout<AudioHardwareIOProcStreamUsage>.size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<total {
            flags[index] = index < deviceInputs ? 0 : 1
        }
        var address = propertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
        if status != noErr {
            NSLog("VolumeMixer: could not turn off device inputs (%d); the microphone may open", status)
        }
    }
}
