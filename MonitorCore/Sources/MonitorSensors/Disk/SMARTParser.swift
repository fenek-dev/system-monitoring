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

    static func map(_ raw: RawSMARTValues, model: String? = nil, capacityBytes: UInt64? = nil) -> SMARTInfo {
        SMARTInfo(
            model: model,
            capacityBytes: capacityBytes,
            status: status(criticalWarning: raw.criticalWarning, percentageUsed: raw.percentageUsed),
            percentageUsed: Double(raw.percentageUsed),
            dataReadBytes: raw.dataUnitsRead * bytesPerDataUnit,
            dataWrittenBytes: raw.dataUnitsWritten * bytesPerDataUnit,
            temperatureC: Double(raw.temperatureKelvin) - 273.15,
            powerOnHours: Int(raw.powerOnHours),
            unsafeShutdowns: Int(raw.unsafeShutdowns),
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
