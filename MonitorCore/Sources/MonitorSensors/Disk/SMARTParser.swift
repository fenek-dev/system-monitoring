import Foundation
import MonitorModel

/// Plain-data mirror of the fields `nvme_smart_read` (CPrivate) fills in on success — decoupled from
/// the C `NVMeSMARTResult` struct so the decode (findings/extras.md §2: 128-bit data units, taken as
/// their low 64 bits by the C layer, ×512000 = bytes; Kelvin -> Celsius; status thresholds) is a pure
/// function, testable with fixtures and no IOKit/CFPlugIn involved.
struct RawSMARTValues: Codable, Equatable {
    var criticalWarning: UInt8
    var temperatureKelvin: UInt16
    var percentageUsed: UInt8
    var dataUnitsRead: UInt64
    var dataUnitsWritten: UInt64
    var powerOnHours: UInt64
    var unsafeShutdowns: UInt64
}

enum SMARTParser {
    /// NVMe log-page "Data Units" are counted in units of 512,000 bytes (findings §2), not 512 —
    /// that's the one arithmetic detail this decode must not get wrong.
    static let bytesPerDataUnit: UInt64 = 512_000

    /// A single attempt at the NVMe SMART plugin path: found nothing at all, a full decoded reading,
    /// or a specific failure (`nvme_smart_read`'s `stage`/`ioReturn`). The FFI layer's only job is
    /// producing one of these; everything downstream (`resolve`) is pure.
    enum NVMeAttempt {
        case notFound
        case success(RawSMARTValues, model: String?, capacityBytes: UInt64?)
        case failed(stage: Int32, ioReturn: Int32)
    }

    enum Outcome {
        case reading(SMARTInfo)
        case failure(SensorError)
    }

    /// Full decision policy (brief: "NVMe SMART plugin per findings, else status only"; ARCHITECTURE
    /// §6's SMART status-only panel). A read failure at stage 3 (SMARTReadData itself, on a
    /// controller that DID accept the plugin) is a real glitch worth retrying — no status-only
    /// fallback there. Everything else (no service found, or the plugin/QueryInterface stages
    /// failed — i.e. this controller doesn't actually expose the NVMe interface even though something
    /// claimed "NVMe SMART Capable") falls back to whatever legacy ATA/AHCI "SMART Status" the caller
    /// found; only if there's truly nothing at all does this become `.unavailable`.
    static func resolve(nvme: NVMeAttempt, legacyStatus: String?) -> Outcome {
        switch nvme {
        case .success(let raw, let model, let capacityBytes):
            return .reading(map(raw, model: model, capacityBytes: capacityBytes))
        case .failed(let stage, let ioReturn) where stage == 3:
            return .failure(error(forStage: stage, ioReturn: ioReturn))
        case .failed, .notFound:
            if let legacyStatus {
                return .reading(SMARTInfo(status: status(fromLegacyStatusString: legacyStatus)))
            }
            return .failure(.unavailable("No SMART data (NVMe or legacy) available for this drive"))
        }
    }

    /// Never traps on garbage hardware data: an overflowing ×512000 multiply clamps to `UInt64.max`
    /// rather than crashing, and `powerOnHours`/`unsafeShutdowns` clamp into `Int`'s range the same
    /// way. `temperatureKelvin == 0` (never a real drive temperature) reads as "not reported" (`nil`)
    /// rather than a nonsensical -273.15°C.
    static func map(_ raw: RawSMARTValues, model: String? = nil, capacityBytes: UInt64? = nil) -> SMARTInfo {
        let (dataRead, readOverflowed) = raw.dataUnitsRead.multipliedReportingOverflow(by: bytesPerDataUnit)
        let (dataWritten, writtenOverflowed) = raw.dataUnitsWritten.multipliedReportingOverflow(by: bytesPerDataUnit)
        return SMARTInfo(
            model: model,
            capacityBytes: capacityBytes,
            status: status(criticalWarning: raw.criticalWarning, percentageUsed: raw.percentageUsed),
            percentageUsed: Double(raw.percentageUsed),
            dataReadBytes: readOverflowed ? .max : dataRead,
            dataWrittenBytes: writtenOverflowed ? .max : dataWritten,
            temperatureC: raw.temperatureKelvin == 0 ? nil : Double(raw.temperatureKelvin) - 273.15,
            powerOnHours: Int(clamping: raw.powerOnHours),
            unsafeShutdowns: Int(clamping: raw.unsafeShutdowns),
            criticalWarning: raw.criticalWarning
        )
    }

    /// Any critical-warning bit set (NVMe spec: spare low, temperature, reliability degraded, R/O,
    /// backup device failed) is a hardware-reported failing condition; a high wear percentage is a
    /// softer warning even with no critical bits set.
    static func status(criticalWarning: UInt8, percentageUsed: UInt8) -> SMARTStatus {
        if criticalWarning != 0 { return .failing }
        if percentageUsed >= 90 { return .warning }
        return .healthy
    }

    /// Legacy ATA/AHCI `"SMART Status"` property string -> `SMARTStatus` (brief: "else status only").
    static func status(fromLegacyStatusString value: String) -> SMARTStatus {
        switch value {
        case "Verified": .healthy
        case "Failing": .failing
        default: .unknown
        }
    }

    /// Maps `nvme_smart_read`'s failure `stage`/`ioReturn` (CPrivate/include/NVMeSMART.h) to a
    /// `SensorError`. Stage 1/2 (plugin creation/QueryInterface failed) means this controller doesn't
    /// actually support the SMART interface — permanent for this launch. Stage 3 (SMARTReadData
    /// itself failed) is a single read glitch — worth retrying at the next cadence tick.
    static func error(forStage stage: Int32, ioReturn: Int32) -> SensorError {
        let hex = String(format: "0x%08x", UInt32(bitPattern: ioReturn))
        switch stage {
        case 1, 2:
            return .unavailable("NVMe SMART plugin unavailable (stage \(stage), ioReturn \(hex))")
        default:
            return .transient("SMARTReadData failed (stage \(stage), ioReturn \(hex))")
        }
    }
}
