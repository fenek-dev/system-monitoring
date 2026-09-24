import CPrivate
import IOKit
import MonitorModel

/// NVMe SMART via the `NVMeSMARTLib` CFPlugIn (findings/extras.md §2). The plugin is opened, read,
/// and torn down fresh on every `sample()` ("open or close the plugin per read" per the brief) — at a
/// 300 s, demand-gated (`.smart`) cadence the ~0.6 ms lookup + ~2-3 ms read cost is negligible, and
/// this avoids holding a CFPlugIn/Mach-connection handle (non-Sendable C pointers) across calls.
///
/// CRITICAL (findings §2): the plugin must stay alive until *after* `(*smart)->Release(smart)` — that
/// ordering lives entirely in CPrivate/nvme_smart.c, which this sensor never second-guesses.
public final class SMARTSensor: Sensor {
    public typealias Reading = SMARTInfo
    public let id: SensorID = .smart
    public let cadence: SensorCadence = .every(.seconds(300), requires: .smart)

    public init() {}

    public func prepare() throws(SensorError) {
        guard let lookup = Self.locateService() else {
            throw .unavailable("No NVMe SMART capable device found")
        }
        IOObjectRelease(lookup.service)
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SMARTInfo, capturedNs: UInt64) {
        guard let lookup = Self.locateService() else {
            throw .transient("NVMe SMART capable device not found (was it unplugged?)")
        }
        let result = nvme_smart_read(lookup.service)
        IOObjectRelease(lookup.service)

        guard result.success != 0 else {
            throw SMARTParser.error(forStage: result.stage, ioReturn: result.ioReturn)
        }
        let raw = RawSMARTValues(
            criticalWarning: result.criticalWarning,
            temperatureKelvin: result.temperatureKelvin,
            percentageUsed: result.percentageUsed,
            dataUnitsRead: result.dataUnitsRead,
            dataUnitsWritten: result.dataUnitsWritten,
            powerOnHours: result.powerOnHours,
            unsafeShutdowns: result.unsafeShutdowns
        )
        let info = SMARTParser.map(raw, model: lookup.model, capacityBytes: ttInternalDriveCapacityBytes())
        return (info, ctx.uptimeNs)
    }

    public func invalidate() {}

    /// Targeted parent-chain walk from the internal drive's BSD name (findings §2: ~0.6 ms); falls
    /// back to a full registry sweep (~11 ms) only if that finds nothing.
    private static func locateService() -> TTNVMeSMARTLookup? {
        guard let bsdName = ttInternalDriveBSDName() else { return nil }
        if let found = ttFindNVMeSMARTService(bsdName: bsdName) { return found }
        let swept = ttFindNVMeSMARTServiceBySweep()
        return swept != 0 ? TTNVMeSMARTLookup(service: swept, model: nil) : nil
    }
}
