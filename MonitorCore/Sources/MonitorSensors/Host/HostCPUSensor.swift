import Darwin
import Foundation
import IOKit
import MonitorModel

// MARK: - Parse layer (pure)

enum HostCPUParser {
    /// `PROCESSOR_CPU_LOAD_INFO` (`integer_t[cpu][CPU_STATE_MAX]`) → raw per-core `[user, system, idle, nice]`.
    static func coreTicks(_ raw: [Int32], cpuCount: Int) -> [[UInt32]] {
        let states = Int(CPU_STATE_MAX)
        let n = min(cpuCount, raw.count / states)
        return (0..<n).map { c in
            let b = c * states
            return [raw[b + Int(CPU_STATE_USER)], raw[b + Int(CPU_STATE_SYSTEM)],
                    raw[b + Int(CPU_STATE_IDLE)], raw[b + Int(CPU_STATE_NICE)]].map { UInt32(bitPattern: $0) }
        }
    }
}

/// Extends the kernel's 32-bit per-core tick counters to 64 bits (wrap-safe), so the engine's
/// guarded deltas never see a spurious decrease.
struct TickAccumulator {
    private var lastRaw: [[UInt32]] = []
    private var totals: [CoreTicks] = []

    mutating func update(_ raw: [[UInt32]]) -> [CoreTicks] {
        if raw.count != lastRaw.count || raw.contains(where: { $0.count != 4 }) {
            lastRaw = raw
            totals = raw.map { CoreTicks(user: UInt64($0[safe: 0]), system: UInt64($0[safe: 1]),
                                         idle: UInt64($0[safe: 2]), nice: UInt64($0[safe: 3])) }
            return totals
        }
        for c in raw.indices {
            let old = lastRaw[c], new = raw[c]
            totals[c].user &+= Self.step(new[0], old[0])
            totals[c].system &+= Self.step(new[1], old[1])
            totals[c].idle &+= Self.step(new[2], old[2])
            totals[c].nice &+= Self.step(new[3], old[3])
        }
        lastRaw = raw
        return totals
    }

    /// Modular 32-bit difference: correct across one wrap. A "step" above 2^31 is a backwards jump (counter reset,
    /// not ~249 days of ticks within one interval): count from zero instead.
    private static func step(_ new: UInt32, _ old: UInt32) -> UInt64 {
        let d = new.subtractingReportingOverflow(old).partialValue
        return d > UInt32(1) << 31 ? UInt64(new) : UInt64(d)
    }
}

private extension Array where Element == UInt32 {
    subscript(safe i: Int) -> UInt32 { i < count ? self[i] : 0 }
}

enum CoreKindParser {
    struct Entry: Sendable, Equatable, Codable {
        var logicalID: Int
        var kind: CoreKind
    }

    /// Device-tree `cluster-type` ("E"/"P", NUL-padded).
    static func kind(clusterType: Data) -> CoreKind? {
        switch clusterType.first {
        case UInt8(ascii: "E"): .efficiency
        case UInt8(ascii: "P"): .performance
        default: nil
        }
    }

    /// Per logical CPU. Device tree when it covers every id 0..<cpuCount; else `hw.perflevel*` counts with the
    /// efficiency cores numbered first (Apple Silicon convention); else all performance.
    static func kinds(deviceTree: [Entry], cpuCount: Int, performance: Int, efficiency: Int) -> [CoreKind] {
        var byID: [Int: CoreKind] = [:]
        for e in deviceTree where e.logicalID >= 0 && e.logicalID < cpuCount { byID[e.logicalID] = e.kind }
        if byID.count == cpuCount, cpuCount > 0 {
            return (0..<cpuCount).map { byID[$0]! }
        }
        if performance + efficiency == cpuCount, efficiency > 0 {
            return Array(repeating: .efficiency, count: efficiency) + Array(repeating: .performance, count: performance)
        }
        return Array(repeating: .performance, count: cpuCount)
    }
}

// MARK: - FFI layer

enum HostCPUFFI {
    static func loadInfo() throws(SensorError) -> (raw: [Int32], cpuCount: Int) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS else { throw w6aMachError(kr, "host_processor_info") }
        guard let info else { throw SensorError.transient("host_processor_info returned no data") }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (Array(UnsafeBufferPointer(start: info, count: Int(infoCount))), Int(cpuCount))
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    /// `IODeviceTree:/cpus/*`: `logical-cpu-id` + `cluster-type`.
    static func deviceTreeCores() -> [CoreKindParser.Entry] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [CoreKindParser.Entry] = []
        while case let c = IOIteratorNext(it), c != 0 {
            defer { IOObjectRelease(c) }
            guard let idRef = IORegistryEntryCreateCFProperty(c, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(),
                  let typeRef = IORegistryEntryCreateCFProperty(c, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() else { continue }
            let id: Int?
            if let n = idRef as? NSNumber {
                id = n.intValue
            } else if let d = idRef as? Data, d.count >= 4 {
                id = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            } else {
                id = nil
            }
            guard let id, let data = typeRef as? Data, let kind = CoreKindParser.kind(clusterType: data) else { continue }
            out.append(.init(logicalID: id, kind: kind))
        }
        return out
    }
}

// MARK: - Sensor

/// Per-core ticks (`host_processor_info`, widened to 64 bits), core kinds (device tree / `hw.perflevel*`), load average.
public final class HostCPUSensor: Sensor {
    public typealias Reading = HostCPUReading
    public let id = SensorID.hostCPU
    public let cadence = SensorCadence.everyTick

    private var kinds: [CoreKind]?
    private var accumulator = TickAccumulator()

    public init() {}

    public func prepare() throws(SensorError) {
        guard kinds == nil else { return }
        let (_, count) = try HostCPUFFI.loadInfo()
        // hw.perflevel0 = performance, hw.perflevel1 = efficiency on Apple Silicon.
        let p = HostCPUFFI.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let e = HostCPUFFI.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        kinds = CoreKindParser.kinds(deviceTree: HostCPUFFI.deviceTreeCores(), cpuCount: count, performance: p, efficiency: e)
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: HostCPUReading, capturedNs: UInt64) {
        if kinds == nil { try prepare() }
        let (raw, count) = try HostCPUFFI.loadInfo()
        let captured = w6aUptimeNs()
        let cores = accumulator.update(HostCPUParser.coreTicks(raw, cpuCount: count))
        var load = [Double](repeating: 0, count: 3)
        let n = getloadavg(&load, 3)
        var coreKinds = kinds ?? []
        if coreKinds.count != cores.count {   // CPU count changed (should not happen): rebuild on next prepare
            coreKinds = Array(repeating: .performance, count: cores.count)
            kinds = nil
        }
        return (HostCPUReading(cores: cores, coreKinds: coreKinds, loadAverage: n == 3 ? load : []), captured)
    }

    public func invalidate() {
        kinds = nil
        accumulator = TickAccumulator()
    }
}
