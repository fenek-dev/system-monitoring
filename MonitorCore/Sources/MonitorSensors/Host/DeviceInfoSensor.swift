import CPrivate
import Darwin
import Foundation
import IOKit
import MonitorModel

// MARK: - Parse layer (pure)

/// Raw inputs for `DeviceInfo`, captured once per launch.
struct DeviceRaw: Sendable, Equatable, Codable {
    var hwModel: String?           // sysctl hw.model
    var osBuild: String?           // sysctl kern.osversion
    var osVersion: [Int]           // ProcessInfo major, minor, patch
    var productName: String?       // IODeviceTree:/product product-name
    var socName: String?           // IODeviceTree:/product product-soc-name
    var brandString: String?       // sysctl machdep.cpu.brand_string
    var performanceCores: Int      // hw.perflevel0.physicalcpu
    var efficiencyCores: Int       // hw.perflevel1.physicalcpu
    var gpuCores: Int?             // AGXAccelerator gpu-core-count
    var memoryBytes: UInt64        // hw.memsize
    var dramType: String?          // IODeviceTree:/chosen dram-type
    var bootTimeSec: Int           // kern.boottime
    var bootTimeUsec: Int
    var hasBattery: Bool           // AppleSmartBattery BatteryInstalled
    var fanCount: Int?             // SMC FNum
}

/// Per-chip facts IOKit does not expose: unified-memory bandwidth and Neural Engine cores (Apple spec sheets).
enum ChipCatalog {
    struct Spec: Equatable {
        var bandwidth: String
        var neuralEngineCores: Int
    }

    static func spec(chip: String, gpuCores: Int?) -> Spec? {
        guard chip.hasPrefix("Apple ") else { return nil }
        let family = String(chip.dropFirst("Apple ".count))
        let gpu = gpuCores ?? 0
        let gbps: Int
        switch family {
        case "M1": gbps = 68
        case "M1 Pro", "M2 Pro": gbps = 200
        case "M1 Max", "M2 Max": gbps = 400
        case "M1 Ultra", "M2 Ultra": gbps = 800
        case "M2", "M3": gbps = 100
        case "M3 Pro": gbps = 150
        case "M3 Max": gbps = gpu > 30 ? 400 : 300
        case "M3 Ultra": gbps = 819
        case "M4": gbps = 120
        case "M4 Pro": gbps = 273
        case "M4 Max": gbps = gpu > 32 ? 546 : 410
        case "M5": gbps = 153
        default: return nil
        }
        return Spec(bandwidth: "\(gbps) GB/s", neuralEngineCores: family.hasSuffix("Ultra") ? 32 : 16)
    }
}

enum DeviceInfoParser {
    static func info(_ r: DeviceRaw) -> DeviceInfo {
        let chip = nonEmpty(r.socName) ?? nonEmpty(r.brandString) ?? "Apple Silicon"
        let spec = ChipCatalog.spec(chip: chip, gpuCores: r.gpuCores)
        return DeviceInfo(
            hwModel: r.hwModel ?? "",
            osBuild: r.osBuild ?? "",
            modelName: nonEmpty(r.productName) ?? nonEmpty(r.hwModel) ?? "Mac",
            chipName: chip,
            performanceCores: r.performanceCores,
            efficiencyCores: r.efficiencyCores,
            gpuCores: r.gpuCores,
            neuralEngineCores: spec?.neuralEngineCores,
            memoryBytes: r.memoryBytes,
            memoryType: nonEmpty(r.dramType),
            memoryBandwidth: spec?.bandwidth,
            bootTime: Date(timeIntervalSince1970: TimeInterval(r.bootTimeSec) + TimeInterval(r.bootTimeUsec) / 1_000_000),
            osVersion: osVersion(r.osVersion),
            hasBattery: r.hasBattery,
            fanCount: r.fanCount                   // nil = SMC unreachable: unknown, not "no fans" (U-I2)
        )
    }

    /// "macOS 26.5" (patch shown only when non-zero).
    static func osVersion(_ v: [Int]) -> String {
        guard v.count >= 2 else { return v.first.map { "macOS \($0)" } ?? "macOS" }
        var parts = [v[0], v[1]]
        if v.count > 2, v[2] != 0 { parts.append(v[2]) }
        return "macOS " + parts.map(String.init).joined(separator: ".")
    }

    /// Device-tree string property: bytes up to the first NUL; nil when empty.
    static func string(fromDeviceTree data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - FFI layer

enum DeviceInfoFFI {
    static func sysctlString(_ name: String) -> String? {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func registryProperty(_ path: String, _ key: String) -> CFTypeRef? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func deviceTreeString(_ path: String, _ key: String) -> String? {
        (registryProperty(path, key) as? Data).flatMap(DeviceInfoParser.string(fromDeviceTree:))
    }

    static func serviceProperty(_ className: String, _ key: String) -> CFTypeRef? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        return IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func hasBattery() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let installed = IORegistryEntryCreateCFProperty(svc, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return installed ?? true
    }

    /// SMC `FNum` (ui8). nil when SMC is not reachable.
    static func fanCount() -> Int? {
        let conn = smc_open()
        guard conn != 0 else { return nil }
        defer { smc_close(conn) }
        var type: UInt32 = 0
        var size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard smc_read(conn, "FNum", &type, &bytes, &size) == 0, size >= 1 else { return nil }
        return Int(bytes[0])
    }

    static func raw() -> DeviceRaw {
        var boot = timeval()
        var len = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &len, nil, 0) != 0 { boot = timeval() }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceRaw(
            hwModel: sysctlString("hw.model"),
            osBuild: sysctlString("kern.osversion"),
            osVersion: [v.majorVersion, v.minorVersion, v.patchVersion],
            productName: deviceTreeString("IODeviceTree:/product", "product-name"),
            socName: deviceTreeString("IODeviceTree:/product", "product-soc-name"),
            brandString: sysctlString("machdep.cpu.brand_string"),
            performanceCores: HostCPUFFI.sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            efficiencyCores: HostCPUFFI.sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            gpuCores: (serviceProperty("AGXAccelerator", "gpu-core-count") as? NSNumber)?.intValue,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            dramType: deviceTreeString("IODeviceTree:/chosen", "dram-type"),
            bootTimeSec: boot.tv_sec,
            bootTimeUsec: Int(boot.tv_usec),
            hasBattery: hasBattery(),
            fanCount: fanCount()
        )
    }
}

// MARK: - Sensor

/// Static device facts; sampled once per launch.
public final class DeviceInfoSensor: Sensor {
    public typealias Reading = DeviceInfo
    public let id = SensorID.device
    public let cadence = SensorCadence.once

    public init() {}

    public func prepare() throws(SensorError) {}

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: DeviceInfo, capturedNs: UInt64) {
        (DeviceInfoParser.info(DeviceInfoFFI.raw()), w6aUptimeNs())
    }

    public func invalidate() {}
}
