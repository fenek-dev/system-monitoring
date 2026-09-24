import CPrivate
import Foundation
import MonitorModel

/// SoC power, cluster residency and MHz from libIOReport (weak-linked; docs/findings/ioreport.md).
/// One subscription (Energy Model + CPU Complex + GPU Performance States + SoC Cluster Power States),
/// filtered to the channels the parse layer uses; each `sample()` deltas against the previous sample.
public final class IOReportSensor: Sensor {
    public typealias Reading = SoCPowerReading
    public let id: SensorID = .soc
    public let cadence: SensorCadence = .everyTick

    /// Deltas shorter than this are noise: the first sample waits (once, ≤ this), later ones return the last reading.
    static let minInterval: UInt64 = 100_000_000

    private var subscription: IOReportSubscription?
    private var subscribed: CFMutableDictionary?
    private var previous: (sample: CFDictionary, ns: UInt64)?
    private var last: (reading: SoCPowerReading, ns: UInt64)?
    private var pstates: PStateTables?
    private let model: String
    /// Decoded channels of the last delta (fixture capture / diagnostics).
    private(set) var lastChannels: [IOReportChannelSample] = []

    public init() { model = w6bHWModel }
    init(model: String) { self.model = model }

    public func prepare() throws(SensorError) {
        guard subscription == nil else { return }
        guard tt_ioreport_available() else { throw .unavailable("libIOReport symbols missing") }
        pstates = (try? PStateCatalog.bundled())?.tables(forModel: model)

        guard let desired = Self.channels(IOReportParse.energyGroup, nil, keep: Self.keepEnergy) else {
            throw .unavailable("IOReport: no Energy Model channels")
        }
        for (group, subgroup, keep) in [
            (IOReportParse.cpuStatsGroup, IOReportParse.clusterSubgroup, Self.keepCluster),
            (IOReportParse.gpuStatsGroup, IOReportParse.gpuSubgroup, { $0 == "GPUPH" }),
            (IOReportParse.socStatsGroup, IOReportParse.clusterPowerSubgroup, { IOReportParse.mediaChannels[$0] != nil }),
        ] as [(String, String, (String) -> Bool)] {
            if let more = Self.channels(group, subgroup, keep: keep) { IOReportMergeChannels(desired, more, nil) }
        }
        var subscribedRef: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, desired, &subscribedRef, 0, nil),
              // Ownership of the out-param is undocumented: take it unretained (at worst one leak per prepare).
              let subDict = subscribedRef?.takeUnretainedValue() else {
            throw .unavailable("IOReportCreateSubscription failed")
        }
        subscription = sub
        subscribed = subDict
        guard let first = IOReportCreateSamples(sub, subDict, nil) else {
            invalidate()
            throw .transient("IOReportCreateSamples failed")
        }
        previous = (first, w6bUptimeNs())
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SoCPowerReading, capturedNs: UInt64) {
        if subscription == nil { try prepare() }
        guard let sub = subscription, let subDict = subscribed, let prev = previous else {
            throw .unavailable("IOReport not prepared")
        }
        var now = w6bUptimeNs()
        if now - prev.ns < Self.minInterval {
            if let last { return (last.reading, last.ns) }
            usleep(useconds_t((Self.minInterval - (now - prev.ns)) / 1000))
        }
        guard let cur = IOReportCreateSamples(sub, subDict, nil) else { throw .transient("IOReportCreateSamples failed") }
        now = w6bUptimeNs()
        previous = (cur, now)
        guard let delta = IOReportCreateSamplesDelta(prev.sample, cur, nil) else {
            throw .transient("IOReportCreateSamplesDelta failed")
        }
        let channels = Self.decode(delta)
        lastChannels = channels
        let reading = IOReportParse.reading(channels: channels, interval: .nanoseconds(Int64(now - prev.ns)), pstates: pstates)
        last = (reading, now)
        return (reading, now)
    }

    public func invalidate() {
        subscription = nil
        subscribed = nil
        previous = nil
        last = nil
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
