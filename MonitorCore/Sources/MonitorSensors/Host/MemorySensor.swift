import Darwin
import MonitorModel

// MARK: - Parse layer (pure)

/// Raw kernel values for one memory sample: `host_statistics64(HOST_VM_INFO64)` page counts, `hw.memsize`,
/// `vm.swapusage`, `kern.memorystatus_vm_pressure_level`, `kern.memorystatus_level`, swap file count.
struct MemoryRaw: Sendable, Equatable, Codable {
    var pageSize: UInt64
    var total: UInt64
    var freeCount: UInt64
    var activeCount: UInt64
    var inactiveCount: UInt64
    var speculativeCount: UInt64
    var wireCount: UInt64
    var purgeableCount: UInt64
    var externalCount: UInt64            // file-backed
    var internalCount: UInt64            // anonymous
    var compressorCount: UInt64          // pages occupied by the compressor
    var uncompressedInCompressor: UInt64 // pages stored in the compressor (original size)
    var pageins: UInt64
    var pageouts: UInt64
    var swapins: UInt64
    var swapouts: UInt64
    var swapTotal: UInt64
    var swapUsed: UInt64
    var swapFiles: Int?
    var pressureLevel: Int32?
    /// `kern.memorystatus_level`: system-wide free percentage, as printed by `memory_pressure`.
    var freePercent: Int32?
}

enum MemoryParser {
    /// Page classes → **bytes** (× page size, saturating); `free` excludes speculative pages like `vm_stat`.
    /// `pageins`/`pageouts`/`swapins`/`swapouts` stay cumulative **page counts**.
    static func reading(_ r: MemoryRaw) -> MemoryReading {
        func bytes(_ pages: UInt64) -> UInt64 {
            let (v, o) = pages.multipliedReportingOverflow(by: r.pageSize)
            return o ? .max : v
        }
        return MemoryReading(
            pageSize: r.pageSize,
            total: r.total,
            free: bytes(w6aCounterDelta(r.freeCount, r.speculativeCount) ?? 0),
            active: bytes(r.activeCount),
            inactive: bytes(r.inactiveCount),
            speculative: bytes(r.speculativeCount),
            wired: bytes(r.wireCount),
            purgeable: bytes(r.purgeableCount),
            fileBacked: bytes(r.externalCount),
            anonymous: bytes(r.internalCount),
            compressorBytes: bytes(r.compressorCount),
            compressedOriginalBytes: bytes(r.uncompressedInCompressor),
            pageins: r.pageins,
            pageouts: r.pageouts,
            swapins: r.swapins,
            swapouts: r.swapouts,
            swapTotal: r.swapTotal,
            swapUsed: r.swapUsed,
            swapFileCount: r.swapFiles,
            pressureLevel: pressureLevel(r.pressureLevel),
            pressureFraction: pressureFraction(freePercent: r.freePercent)
        )
    }

    static func pressureLevel(_ raw: Int32?) -> MemoryPressureLevel? {
        raw.flatMap { MemoryPressureLevel(rawValue: Int($0)) }
    }

    /// 0 = no pressure … 1 = none free: `1 − memorystatus_level / 100`.
    static func pressureFraction(freePercent: Int32?) -> Double? {
        guard let p = freePercent, (0...100).contains(p) else { return nil }
        return Double(100 - p) / 100
    }
}

// MARK: - FFI layer

enum MemoryFFI {
    /// Fixed-size sysctl value (POD `T`); nil on error or size mismatch.
    static func sysctlValue<T: BitwiseCopyable>(_ name: String, _ type: T.Type) -> T? {
        withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buf -> T? in
            var len = MemoryLayout<T>.size
            guard sysctlbyname(name, buf.baseAddress, &len, nil, 0) == 0, len == MemoryLayout<T>.size else { return nil }
            return UnsafeRawPointer(buf.baseAddress!).load(as: T.self)
        }
    }

    static func pageSize() -> UInt64 {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else { return UInt64(getpagesize()) }
        return UInt64(size)
    }

    static func vmStatistics() throws(SensorError) -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw SensorError.posix(kr, "host_statistics64(HOST_VM_INFO64)") }
        return stats
    }

    /// `swapfile*` entries in the VM volume.
    static func swapFileCount() -> Int? {
        for dir in ["/System/Volumes/VM", "/private/var/vm"] {
            guard let d = opendir(dir) else { continue }
            defer { closedir(d) }
            var n = 0
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name.hasPrefix("swapfile") { n += 1 }
            }
            return n
        }
        return nil
    }

    static func raw(pageSize: UInt64, total: UInt64) throws(SensorError) -> MemoryRaw {
        let s = try vmStatistics()
        let swap = sysctlValue("vm.swapusage", xsw_usage.self)
        return MemoryRaw(
            pageSize: pageSize,
            total: total,
            freeCount: UInt64(s.free_count),
            activeCount: UInt64(s.active_count),
            inactiveCount: UInt64(s.inactive_count),
            speculativeCount: UInt64(s.speculative_count),
            wireCount: UInt64(s.wire_count),
            purgeableCount: UInt64(s.purgeable_count),
            externalCount: UInt64(s.external_page_count),
            internalCount: UInt64(s.internal_page_count),
            compressorCount: UInt64(s.compressor_page_count),
            uncompressedInCompressor: s.total_uncompressed_pages_in_compressor,
            pageins: s.pageins,
            pageouts: s.pageouts,
            swapins: s.swapins,
            swapouts: s.swapouts,
            swapTotal: swap?.xsu_total ?? 0,
            swapUsed: swap?.xsu_used ?? 0,
            swapFiles: swapFileCount(),
            pressureLevel: sysctlValue("kern.memorystatus_vm_pressure_level", Int32.self),
            freePercent: sysctlValue("kern.memorystatus_level", Int32.self)
        )
    }
}

// MARK: - Sensor

/// VM page classes, compressor, swap, memory pressure (`host_statistics64`, `vm.swapusage`, memorystatus).
///
/// Units of the `MemoryReading` it returns:
/// - BYTES (already × `pageSize`): `free` (excl. speculative, as `vm_stat`), `active`, `inactive`, `speculative`,
///   `wired`, `purgeable`, `fileBacked`, `anonymous`; also `total`, `compressorBytes`, `compressedOriginalBytes`,
///   `swapTotal`, `swapUsed`.
/// - cumulative PAGE COUNTS: `pageins`, `pageouts`, `swapins`, `swapouts`.
/// - `pageSize`: bytes per page. `pressureFraction`: 0…1 = 1 − `kern.memorystatus_level`/100.
public final class MemorySensor: Sensor {
    public typealias Reading = MemoryReading
    public let id = SensorID.memory
    public let cadence = SensorCadence.everyTick

    private var pageSize: UInt64 = 0
    private var total: UInt64 = 0

    public init() {}

    public func prepare() throws(SensorError) {
        guard pageSize == 0 else { return }
        guard let mem = MemoryFFI.sysctlValue("hw.memsize", UInt64.self), mem > 0 else {
            throw SensorError.unavailable("hw.memsize unavailable")
        }
        total = mem
        pageSize = MemoryFFI.pageSize()
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: MemoryReading, capturedNs: UInt64) {
        if pageSize == 0 { try prepare() }
        let raw = try MemoryFFI.raw(pageSize: pageSize, total: total)
        return (MemoryParser.reading(raw), w6aUptimeNs())
    }

    public func invalidate() {
        pageSize = 0
    }
}
