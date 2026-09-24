import Darwin
import Foundation
import IOKit
import MonitorModel

/// Monotonic capture time (ARCHITECTURE §5 units: `CLOCK_UPTIME_RAW` ns).
@inline(__always)
func w6bUptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// `sysctlbyname` string ("hw.model" → "MacBookPro18,4", "kern.osversion" → "25F71"); nil on failure.
func w6bSysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Catalog key for this Mac (`hw.model`), "" when unreadable.
let w6bHWModel: String = w6bSysctlString("hw.model") ?? ""
/// OS build ("25F71") for cache file names.
let w6bOSBuild: String = w6bSysctlString("kern.osversion") ?? "unknown"

/// One registry property (+1 copy bridged to ARC). nil when absent.
func w6bRegistryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// All registry properties of an entry; empty on failure.
func w6bRegistryProperties(_ entry: io_registry_entry_t) -> [String: Any] {
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
    return dict
}

/// Loose numeric coercion for plist/CF values (NSNumber, Int, UInt64, Double, Bool).
func w6bNumber(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: n.doubleValue
    case let d as Double: d
    case let i as Int: Double(i)
    case let u as UInt64: Double(u)
    case let i as Int64: Double(i)
    default: nil
    }
}

/// Raw 64-bit pattern of an integer value (two's-complement amperage etc.).
func w6bInt64(_ v: Any?) -> Int64? {
    switch v {
    case let n as NSNumber:
        // NSNumber holding a UInt64 > Int64.max (e.g. 18446744073709548582) must keep its bit pattern.
        if CFNumberIsFloatType(n) { return Int64(exactly: n.doubleValue.rounded()) }
        return Int64(bitPattern: n.uint64Value)
    case let i as Int: return Int64(i)
    case let i as Int64: return i
    case let u as UInt64: return Int64(bitPattern: u)
    default: return nil
    }
}

/// Resource bundle JSON decode (catalogs). Throws `.unavailable` when missing/invalid.
func w6bLoadResource<T: Decodable>(_ name: String, as type: T.Type) throws(SensorError) -> T {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw .unavailable("\(name).json missing from bundle")
    }
    do {
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    } catch {
        throw .unavailable("\(name).json invalid: \(error)")
    }
}

/// p50/p95/max of a latency sample in ms (bench output).
func w6bPercentiles(_ ns: [UInt64]) -> String {
    guard !ns.isEmpty else { return "n=0" }
    let s = ns.sorted()
    func ms(_ q: Double) -> String { String(format: "%.2f", Double(s[min(s.count - 1, Int(Double(s.count) * q))]) / 1e6) }
    return "n=\(s.count) p50=\(ms(0.5))ms p95=\(ms(0.95))ms max=\(String(format: "%.2f", Double(s.last!) / 1e6))ms"
}
