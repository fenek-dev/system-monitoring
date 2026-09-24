import Foundation
import IOKit
import IOKit.ps
import MonitorModel

/// Battery via `AppleSmartBattery` (registry) + IOPowerSources + Low Power Mode. Desktops: `present == false`.
public final class BatterySensor: Sensor {
    public typealias Reading = BatteryReading
    public let id: SensorID = .battery
    public let cadence: SensorCadence = .every(.seconds(5), background: .seconds(30))

    private var service: io_service_t = 0

    public init() {}

    deinit { invalidate() }

    public func prepare() throws(SensorError) {
        guard service == 0 else { return }
        // Absent service is not an error: no battery.
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: BatteryReading, capturedNs: UInt64) {
        let raw = Self.raw(service: service)
        let r = BatteryParse.reading(registry: raw.registry, source: raw.source, providing: raw.providing,
                                     adapter: raw.adapter, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        return (r, w6bUptimeNs())
    }

    public func invalidate() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
    }

    struct Raw {
        var registry: [String: Any]?
        var source: [String: Any]?
        var providing: String?
        var adapter: [String: Any]?
    }

    static func raw(service: io_service_t) -> Raw {
        var raw = Raw()
        if service != 0 {
            let props = w6bRegistryProperties(service)
            raw.registry = props.isEmpty ? nil : props
        }
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            raw.providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                raw.source = d
                break
            }
        }
        raw.adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return raw
    }
}
