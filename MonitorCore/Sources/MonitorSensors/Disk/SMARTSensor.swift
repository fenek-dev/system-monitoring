import CPrivate
import IOKit
import MonitorModel

/// NVMe SMART via the `NVMeSMARTLib` CFPlugIn (findings/extras.md §2), falling back to the legacy
/// ATA/AHCI `"SMART Status"` property for a status-only reading when no working NVMe interface is
/// found (brief: "else status only"; ARCHITECTURE §6's SMART status-only panel) — see
/// `SMARTParser.resolve`, which owns that whole decision purely.
///
/// The plugin is opened, read, and torn down fresh on every `sample()` ("open or close the plugin per
/// read" per the brief) — at a 300 s, demand-gated (`.smart`) cadence the ~0.6 ms lookup + ~2-3 ms
/// read cost is negligible, and this avoids holding a CFPlugIn/Mach-connection handle (non-`Sendable`
/// C pointers) across calls.
///
/// CRITICAL (findings §2): the plugin must stay alive until *after* `(*smart)->Release(smart)` — that
/// ordering lives entirely in CPrivate/nvme_smart.c, which this sensor never second-guesses.
public final class SMARTSensor: Sensor {
    public typealias Reading = SMARTInfo
    public let id: SensorID = .smart
    public let cadence: SensorCadence = .every(.seconds(300), requires: .smart)

    public init() {}

    public func prepare() throws(SensorError) {
        // Cheap existence check only (no sweep, no plugin creation, per the Sensor protocol doc):
        // is there even an internal drive to ask about? The NVMe-vs-legacy-status resolution itself
        // happens fresh in every sample() (a 300 s cadence makes re-resolving trivial).
        guard ttInternalDriveIdentity() != nil else {
            throw .unavailable("No internal drive found")
        }
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SMARTInfo, capturedNs: UInt64) {
        guard let drive = ttInternalDriveIdentity() else {
            throw .unavailable("No internal drive found")
        }
        let nvmeAttempt = Self.attemptNVMeRead(bsdName: drive.bsdName, capacityBytes: drive.capacityBytes)
        let legacyStatus: String?
        if case .success = nvmeAttempt {
            legacyStatus = nil // NVMe succeeded; no need to also walk for the legacy fallback.
        } else {
            legacyStatus = ttReadLegacySMARTStatus(bsdName: drive.bsdName)
        }
        switch SMARTParser.resolve(nvme: nvmeAttempt, legacyStatus: legacyStatus) {
        case .reading(let info): return (info, ctx.uptimeNs)
        case .failure(let error): throw error
        }
    }

    public func invalidate() {}

    /// Targeted parent-chain walk from the internal drive's BSD name (findings §2: ~0.6 ms); falls
    /// back to a full registry sweep (~11 ms) only if that finds nothing. The sweep isn't anchored to
    /// `bsdName` — it may return a *different* physical drive (findings §2: "the first SMART-capable
    /// thing anywhere") — so `model`/`capacityBytes` (which describe `bsdName`'s drive) must never be
    /// attached to a sweep-found result.
    private static func attemptNVMeRead(bsdName: String, capacityBytes: UInt64?) -> SMARTParser.NVMeAttempt {
        if let lookup = ttFindNVMeSMARTService(bsdName: bsdName) {
            let result = nvme_smart_read(lookup.service)
            IOObjectRelease(lookup.service)
            return Self.attempt(from: result, model: lookup.model, capacityBytes: capacityBytes)
        }
        let swept = ttFindNVMeSMARTServiceBySweep()
        guard swept != 0 else { return .notFound }
        let result = nvme_smart_read(swept)
        IOObjectRelease(swept)
        return Self.attempt(from: result, model: nil, capacityBytes: nil)
    }

    private static func attempt(from result: NVMeSMARTResult, model: String?, capacityBytes: UInt64?) -> SMARTParser.NVMeAttempt {
        guard result.success != 0 else {
            return .failed(stage: result.stage, ioReturn: result.ioReturn)
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
        return .success(raw, model: model, capacityBytes: capacityBytes)
    }
}
