import AppKit
import CoreAudio

/// Private call that maps a helper (Safari's WebKit processes) to its app. Looked up at run time
/// so a system without it falls back to the parent chain instead of failing to launch.
private let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
}()

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Publishes the apps registered with the audio system. Callbacks arrive on the main thread.
public final class AudioProcessMonitor {
    public var onChange: (([AppGroup]) -> Void)?
    public var onOutputDeviceChange: (() -> Void)?

    private var timer: Timer?
    private var last: [AppGroup]?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var sampleRate: Float64 = 0
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start() {
        var processList = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(.system, &processList, .main) { [weak self] _, _ in
            self?.refresh()
        }
        var defaultOutput = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(.system, &defaultOutput, .main) { [weak self] _, _ in
            self?.watchOutputDevice()
            self?.onOutputDeviceChange?()
        }
        // The audio server restarting destroys every tap, and apps go back to full volume
        // while the sliders still show the old values.
        var restarted = propertyAddress(kAudioHardwarePropertyServiceRestarted)
        AudioObjectAddPropertyListenerBlock(.system, &restarted, .main) { [weak self] _, _ in
            // Process objects get new IDs, so publish those before the engine rebuilds its taps.
            self?.last = nil
            self?.refresh()
            self?.watchOutputDevice()
            self?.onOutputDeviceChange?()
        }
        // Devices are not ready the instant the machine wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.watchOutputDevice()
                self?.onOutputDeviceChange?()
            }
        }
        watchOutputDevice()
        // The process list listener does not fire for play/pause, so poll for that.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    public func refresh() {
        let groups = AppGrouping.group(readProcesses(), in: processTree(), excluding: getpid())
        guard groups != last else { return }
        last = groups
        onChange?(groups)
    }

    /// Follows the default output device and reports when its sample rate changes (a Bluetooth
    /// headset switching profile), which leaves existing taps running at the wrong rate.
    private func watchOutputDevice() {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        if let sampleRateListener, outputDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(outputDevice, &address, .main, sampleRateListener)
        }
        sampleRateListener = nil
        outputDevice = (try? AudioObjectID.system.readValue(
            kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))) ?? AudioObjectID(kAudioObjectUnknown)
        guard outputDevice != kAudioObjectUnknown else { return }

        let device = outputDevice
        sampleRate = (try? device.readValue(kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.outputDevice == device else { return }
            let current = (try? device.readValue(kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
            // Building a tap can itself post this notification; only a real change counts.
            guard current != self.sampleRate else { return }
            self.sampleRate = current
            self.onOutputDeviceChange?()
        }
        sampleRateListener = listener
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
    }

    private func readProcesses() -> [AudioProcess] {
        let objectIDs = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return objectIDs.compactMap { objectID in
            guard let pid = try? objectID.readValue(kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let bundleID = try? objectID.readString(kAudioProcessPropertyBundleID)
            let running = (try? objectID.readValue(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    private func processTree() -> ProcessTree {
        var regular: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bundleID = app.bundleIdentifier { regular[app.processIdentifier] = bundleID }
        }
        return ProcessTree(
            regularApps: regular,
            responsible: { pid in
                guard let responsible = responsiblePID?(pid), responsible > 0 else { return nil }
                return responsible
            },
            parent: parentPID(of:))
    }
}

/// Resolves a bundle ID to a display name and bundle location.
public final class AppDescriber {
    private var cache: [String: AppDescription] = [:]

    public init() {}

    public func describe(_ bundleID: String) -> AppDescription {
        if let cached = cache[bundleID] { return cached }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = running?.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? bundleID
        let description = AppDescription(name: name, bundleURL: url)
        if url != nil { cache[bundleID] = description }
        return description
    }
}
