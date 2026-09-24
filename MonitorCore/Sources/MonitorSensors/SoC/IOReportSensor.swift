import CPrivate
import Foundation
import MonitorModel
import os

/// SoC power, cluster residency and MHz from libIOReport (weak-linked; docs/findings/ioreport.md).
/// One subscription (Energy Model + CPU Complex + GPU Performance States + SoC Cluster Power States),
/// filtered to the channels the parse layer uses; each `sample()` deltas against the previous sample.
public final class IOReportSensor: Sensor {
    public typealias Reading = SoCPowerReading
    public let id: SensorID = .soc
    public let cadence: SensorCadence = .everyTick

    /// Deltas shorter than this are noise: the first sample waits (once, ≤ this), later ones return the last reading.
    static let minInterval: UInt64 = 100_000_000

    /// A baseline older than this (uptime) is stale: sampling was paused, so the next delta would be an average over
    /// the pause rather than current power.
    static let maxBaselineAgeNs: UInt64 = 15_000_000_000
    /// Continuous time (includes sleep) running ahead of uptime by more than this → the Mac slept since the baseline.
    static let sleepSlackNs: UInt64 = 1_000_000_000

    private var subscription: IOReportSubscription?
    private var subscribed: CFMutableDictionary?
    /// `ns` = uptime (CLOCK_UPTIME_RAW, excludes sleep), `continuousNs` = CLOCK_MONOTONIC_RAW (includes sleep).
    private var previous: (sample: CFDictionary, ns: UInt64, continuousNs: UInt64)?
    private var last: (reading: SoCPowerReading, ns: UInt64)?
    private var pstates: PStateTables?
    private let model: String
    private let uptimeNs: () -> UInt64
    private let continuousNs: () -> UInt64
    /// Decoded channels of the last delta (fixture capture / diagnostics).
    private(set) var lastChannels: [IOReportChannelSample] = []
    /// Times the baseline was dropped after sleep / a long pause (diagnostics, tests).
    private(set) var rebaselines = 0

    /// Pending off-queue setup (channel discovery costs 0.45–0.5 s even in release: `IOReportCopyChannelsInGroup`).
    private var setup: IOReportSetupBox?

    public convenience init() { self.init(model: w6bHWModel) }

    /// Test seam: injected clocks (a jump in `continuousNs` alone simulates a sleep).
    init(model: String, uptimeNs: @escaping () -> UInt64 = w6bUptimeNs,
         continuousNs: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }) {
        self.model = model
        self.uptimeNs = uptimeNs
        self.continuousNs = continuousNs
    }

    /// True when the previous IOReport sample can't be the baseline of the next delta: the Mac slept since (energy
    /// and residency counters may keep moving while the interval, on uptime, excludes the sleep → overstated power),
    /// or it is older than `maxBaselineAgeNs` (paused).
    static func baselineIsStale(uptimeDeltaNs: UInt64, continuousDeltaNs: UInt64) -> Bool {
        let slept = continuousDeltaNs > uptimeDeltaNs && continuousDeltaNs - uptimeDeltaNs > sleepSlackNs
        return slept || uptimeDeltaNs > maxBaselineAgeNs
    }

    /// Cheap: checks the weak symbols, loads the P-state table and starts channel discovery + subscription on a
    /// utility queue. Until that finishes, `sample()` throws `.transient("warming up")`.
    public func prepare() throws(SensorError) {
        guard subscription == nil, setup == nil else { return }
        guard tt_ioreport_available() else { throw .unavailable("libIOReport symbols missing") }
        pstates = (try? PStateCatalog.bundled())?.tables(forModel: model)
        let box = IOReportSetupBox()
        box.start()
        setup = box
    }

    /// Diagnostics (ownership test): the subscribed-channels dictionary.
    var subscribedDictionary: CFMutableDictionary? { subscribed }

    /// Tests / probes: blocks until the off-queue setup finished (or `timeout`). True when ready.
    @discardableResult
    func waitUntilReady(timeout: Duration = .seconds(15)) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if subscription != nil || adoptSetup() { return true }
            if let setup, setup.failure != nil { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return subscription != nil
    }

    /// Moves a finished setup into the sensor (sampler executor only). True when a subscription is now held.
    private func adoptSetup() -> Bool {
        guard let setup, let ready = setup.take() else { return false }
        subscription = ready.subscription
        subscribed = ready.subscribed
        previous = (ready.first, ready.ns, ready.continuousNs)
        self.setup = nil
        return true
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SoCPowerReading, capturedNs: UInt64) {
        if subscription == nil && setup == nil { try prepare() }
        if subscription == nil && !adoptSetup() {
            if let error = setup?.failure {
                setup = nil
                throw error
            }
            // .transient, not .unavailable: .unavailable makes the slot invalidate() and retry only every 5 min (§6.2).
            throw .transient("warming up")
        }
        guard let sub = subscription, let subDict = subscribed, var prev = previous else {
            throw .unavailable("IOReport not prepared")
        }
        var now = uptimeNs()
        let continuous = continuousNs()
        if Self.baselineIsStale(uptimeDeltaNs: now >= prev.ns ? now - prev.ns : 0,
                                continuousDeltaNs: continuous >= prev.continuousNs ? continuous - prev.continuousNs : 0) {
            // Re-baseline (wake / unpause): the first delta after it is dropped, and this call measures a fresh
            // ≥ minInterval window instead, like the first sample after setup.
            // On failure the stale baseline stays, so the next call re-baselines again.
            guard let base = IOReportCreateSamples(sub, subDict, nil) else { throw .transient("IOReportCreateSamples failed") }
            now = uptimeNs()
            prev = (base, now, continuousNs())
            previous = prev
            last = nil
            rebaselines += 1
        }
        let age = now >= prev.ns ? now - prev.ns : 0
        if age < Self.minInterval {
            if let last { return (last.reading, last.ns) }
            usleep(useconds_t((Self.minInterval - age) / 1000))
        }
        guard let cur = IOReportCreateSamples(sub, subDict, nil) else { throw .transient("IOReportCreateSamples failed") }
        now = uptimeNs()
        previous = (cur, now, continuousNs())
        guard let delta = IOReportCreateSamplesDelta(prev.sample, cur, nil) else {
            throw .transient("IOReportCreateSamplesDelta failed")
        }
        let channels = Self.decode(delta)
        lastChannels = channels
        let span = now >= prev.ns ? now - prev.ns : 0
        let reading = IOReportParse.reading(channels: channels, interval: .nanoseconds(Int64(span)), pstates: pstates)
        last = (reading, now)
        return (reading, now)
    }

    public func invalidate() {
        setup = nil                      // a setup still running finishes into its own (dropped) box
        subscription = nil
        subscribed = nil
        previous = nil
        last = nil
    }

    /// Channel discovery + subscription (slow part of setup). Runs on the setup queue.
    static func subscribe() -> Result<IOReportSetupBox.Ready, SensorError> {
        guard let desired = channels(IOReportParse.energyGroup, nil, keep: keepEnergy) else {
            return .failure(.unavailable("IOReport: no Energy Model channels"))
        }
        for (group, subgroup, keep) in [
            (IOReportParse.cpuStatsGroup, IOReportParse.clusterSubgroup, keepCluster),
            (IOReportParse.gpuStatsGroup, IOReportParse.gpuSubgroup, { $0 == "GPUPH" }),
            (IOReportParse.socStatsGroup, IOReportParse.clusterPowerSubgroup, { IOReportParse.mediaChannels[$0] != nil }),
        ] as [(String, String, (String) -> Bool)] {
            if let more = channels(group, subgroup, keep: keep) { IOReportMergeChannels(desired, more, nil) }
        }
        var subscribedRef: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, desired, &subscribedRef, 0, nil) else {
            subscribedRef?.release()
            return .failure(.unavailable("IOReportCreateSubscription failed"))
        }
        // The out-param is +1 (Create rule; CFGetRetainCount == 1 right after the call, and footprint grows
        // ~65 KB per unreleased subscribe/drop cycle): take it retained so ARC balances it.
        guard let subDict = subscribedRef?.takeRetainedValue() else {
            return .failure(.unavailable("IOReportCreateSubscription returned no channels"))
        }
        guard let first = IOReportCreateSamples(sub, subDict, nil) else {
            return .failure(.transient("IOReportCreateSamples failed"))
        }
        return .success(.init(subscription: sub, subscribed: subDict, first: first, ns: w6bUptimeNs(),
                              continuousNs: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)))
    }

    // MARK: - FFI helpers

    static func keepEnergy(_ name: String) -> Bool {
        name == "CPU Energy" || name == "GPU Energy" || name == "GPU0" || name.hasSuffix("_CPU")
            || name.hasPrefix("ANE") || name.hasPrefix("DRAM")
    }

    static func keepCluster(_ name: String) -> Bool { IOReportParse.clusterKind(name) != nil }

    /// Channels of one group/subgroup, filtered by channel name (fewer channels → cheaper samples).
    static func channels(_ group: String, _ subgroup: String?, keep: (String) -> Bool) -> CFMutableDictionary? {
        guard let all = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0) else { return nil }
        let dict = all as NSDictionary
        guard let list = dict["IOReportChannels"] as? [NSDictionary] else { return nil }
        let kept = list.filter { ch in
            (IOReportChannelGetChannelName(ch as CFDictionary) as String?).map(keep) ?? false
        }
        guard !kept.isEmpty else { return nil }
        let copy = NSMutableDictionary(dictionary: dict)
        copy["IOReportChannels"] = NSMutableArray(array: kept)    // IOReportMergeChannels appends in place
        return copy as CFMutableDictionary
    }

    /// CF delta → pure channel values.
    static func decode(_ delta: CFDictionary) -> [IOReportChannelSample] {
        guard let list = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
        var out: [IOReportChannelSample] = []
        out.reserveCapacity(list.count)
        for ns in list {
            let ch = ns as CFDictionary
            let group = IOReportChannelGetGroup(ch) as String? ?? ""
            let subgroup = IOReportChannelGetSubGroup(ch) as String? ?? ""
            let name = IOReportChannelGetChannelName(ch) as String? ?? ""
            var s = IOReportChannelSample(group: group, subgroup: subgroup, name: name)
            switch IOReportChannelGetFormat(ch) {
            case Int32(kTTIOReportFormatSimple):
                s.unit = IOReportChannelGetUnitLabel(ch) as String?
                s.value = IOReportSimpleGetIntegerValue(ch, 0)
            case Int32(kTTIOReportFormatState):
                let n = IOReportStateGetCount(ch)
                guard n > 0, n < 256 else { continue }
                s.states = (0..<n).map { i in
                    IOReportChannelSample.State(
                        name: IOReportStateGetNameForIndex(ch, i) as String? ?? "",
                        residency: IOReportStateGetResidency(ch, i))
                }
            default:
                continue
            }
            out.append(s)
        }
        return out
    }
}

/// Off-queue IOReport setup. The CF results are created on the setup queue and handed over exactly once
/// (`take()`) to the sampler executor; the lock holds them via `uncheckedState` because CF types aren't Sendable.
final class IOReportSetupBox: Sendable {
    struct Ready {
        var subscription: IOReportSubscription
        var subscribed: CFMutableDictionary
        var first: CFDictionary
        var ns: UInt64
        var continuousNs: UInt64
    }

    private enum Phase {
        case running
        case ready(Ready)
        case taken
        case failed(SensorError)
    }

    // `uncheckedState` / `withLockUnchecked`: `Phase.ready` carries CF objects (IOReportSubscription,
    // CFDictionary), which are not `Sendable`. This is sound because (1) they are created on the setup queue and
    // never touched there after being stored, (2) `take()` moves them out exactly once (state → .taken), so
    // afterwards only the sampler executor owns them, and (3) the lock orders the store before the take.
    private let phase = OSAllocatedUnfairLock<Phase>(uncheckedState: .running)
    private static let queue = DispatchQueue(label: "dev.telltale.ioreport-setup", qos: .utility)

    func start() {
        Self.queue.async { [self] in
            let t0 = w6bUptimeNs()
            let result = IOReportSensor.subscribe()
            Logger(subsystem: "dev.telltale", category: "MonitorSensors")
                .debug("IOReport setup \((w6bUptimeNs() - t0) / 1_000_000, privacy: .public) ms")
            phase.withLockUnchecked { p in
                switch result {
                case let .success(r): p = .ready(r)
                case let .failure(e): p = .failed(e)
                }
            }
        }
    }

    /// The finished subscription, once; nil while running / after a failure / when already taken.
    func take() -> Ready? {
        phase.withLockUnchecked { p in
            guard case let .ready(r) = p else { return nil }
            p = .taken
            return r
        }
    }

    var failure: SensorError? {
        phase.withLockUnchecked { p in
            if case let .failed(e) = p { return e }
            return nil
        }
    }
}
