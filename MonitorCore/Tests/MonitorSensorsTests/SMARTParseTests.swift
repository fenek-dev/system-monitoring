import Foundation
import Testing
@testable import MonitorSensors
import MonitorModel

@Suite struct SMARTParseTests {
    private func loadFixture() throws -> RawSMARTValues {
        let url = try #require(Bundle.module.url(forResource: "smart-disk0", withExtension: "json", subdirectory: "Fixtures/W6d"))
        return try JSONDecoder().decode(RawSMARTValues.self, from: Data(contentsOf: url))
    }

    @Test func decodesRealCapturedValuesCrossCheckedAgainstSmartctl() throws {
        let raw = try loadFixture()
        let info = SMARTParser.map(raw, model: "APPLE SSD AP2048R", capacityBytes: 2_001_111_162_880)
        #expect(info.model == "APPLE SSD AP2048R")
        #expect(info.capacityBytes == 2_001_111_162_880)
        #expect(info.status == .healthy)
        #expect(info.percentageUsed == 4)
        // smartctl -a disk0 (same capture): powerOnHours and unsafeShutdowns match exactly
        // (findings/extras.md §2); data units/temperature differ by small live-counter amounts.
        #expect(info.powerOnHours == 4694)
        #expect(info.unsafeShutdowns == 25)
        #expect(info.criticalWarning == 0)
    }

    @Test func dataUnitsConvertToBytesAt512000Multiplier() {
        // Findings §2: NVMe "Data Units" are counted in units of 512,000 bytes, not 512 - the one
        // arithmetic detail this decode must never get wrong.
        let raw = RawSMARTValues(criticalWarning: 0, temperatureKelvin: 300, percentageUsed: 0,
                                  dataUnitsRead: 1, dataUnitsWritten: 2, powerOnHours: 0, unsafeShutdowns: 0)
        let info = SMARTParser.map(raw)
        #expect(info.dataReadBytes == 512_000)
        #expect(info.dataWrittenBytes == 1_024_000)
    }

    @Test func largeDataUnitsDoNotOverflowUInt64() {
        // A real internal SSD's actual reading: ~236.7M data units read (~121 TB) - nowhere near
        // UInt64's ceiling, but confirms the ×512000 multiply is done at full 64-bit width.
        let raw = RawSMARTValues(criticalWarning: 0, temperatureKelvin: 300, percentageUsed: 0,
                                  dataUnitsRead: 236_738_427, dataUnitsWritten: 0, powerOnHours: 0, unsafeShutdowns: 0)
        let info = SMARTParser.map(raw)
        #expect(info.dataReadBytes == 236_738_427 * 512_000)
    }

    @Test func kelvinToCelsiusConversion() {
        let raw = RawSMARTValues(criticalWarning: 0, temperatureKelvin: 314, percentageUsed: 0,
                                  dataUnitsRead: 0, dataUnitsWritten: 0, powerOnHours: 0, unsafeShutdowns: 0)
        let info = SMARTParser.map(raw)
        #expect(info.temperatureC == 314 - 273.15)
    }

    @Test func zeroKelvinReadsAsUnreportedNotAbsoluteZeroCelsius() {
        // 0 K is never a real drive temperature - it means the field wasn't actually filled in.
        let raw = RawSMARTValues(criticalWarning: 0, temperatureKelvin: 0, percentageUsed: 0,
                                  dataUnitsRead: 0, dataUnitsWritten: 0, powerOnHours: 0, unsafeShutdowns: 0)
        let info = SMARTParser.map(raw)
        #expect(info.temperatureC == nil)
    }

    @Test func overflowingDataUnitsClampsToUInt64MaxInsteadOfCrashing() {
        // dataUnitsRead × 512,000 overflows UInt64 once dataUnitsRead exceeds ~3.6×10^13 - garbage
        // hardware data must clamp, never trap.
        let raw = RawSMARTValues(criticalWarning: 0, temperatureKelvin: 300, percentageUsed: 0,
                                  dataUnitsRead: .max, dataUnitsWritten: .max, powerOnHours: .max, unsafeShutdowns: .max)
        let info = SMARTParser.map(raw)
        #expect(info.dataReadBytes == .max)
        #expect(info.dataWrittenBytes == .max)
        #expect(info.powerOnHours == Int.max)
        #expect(info.unsafeShutdowns == Int.max)
    }

    @Test func criticalWarningBitSetMeansFailing() {
        #expect(SMARTParser.status(criticalWarning: 0x01, percentageUsed: 0) == .failing)
        #expect(SMARTParser.status(criticalWarning: 0x80, percentageUsed: 0) == .failing)
    }

    @Test func highWearWithNoCriticalBitsIsWarning() {
        #expect(SMARTParser.status(criticalWarning: 0, percentageUsed: 90) == .warning)
        #expect(SMARTParser.status(criticalWarning: 0, percentageUsed: 100) == .warning)
    }

    @Test func lowWearNoCriticalBitsIsHealthy() {
        #expect(SMARTParser.status(criticalWarning: 0, percentageUsed: 4) == .healthy)
        #expect(SMARTParser.status(criticalWarning: 0, percentageUsed: 89) == .healthy)
    }

    @Test func stage1And2MapToUnavailablePermanentForThisLaunch() {
        guard case .unavailable = SMARTParser.error(forStage: 1, ioReturn: -536870190) else {
            Issue.record("expected .unavailable for stage 1")
            return
        }
        guard case .unavailable = SMARTParser.error(forStage: 2, ioReturn: -536870190) else {
            Issue.record("expected .unavailable for stage 2")
            return
        }
    }

    @Test func stage3MapsToTransient() {
        // The exact failure findings/extras.md §2 documents before the plugin-lifetime fix: 0x10000003
        // "(ipc/send) invalid destination port" - a read-time IPC failure, not a capability gap.
        guard case .transient = SMARTParser.error(forStage: 3, ioReturn: Int32(bitPattern: 0x1000_0003)) else {
            Issue.record("expected .transient for stage 3")
            return
        }
    }

    // MARK: - Legacy ATA/AHCI "SMART Status" fallback (review fix: brief "else status only";
    // ARCHITECTURE §6's SMART status-only panel)

    @Test func legacyVerifiedMapsToHealthy() {
        #expect(SMARTParser.status(fromLegacyStatusString: "Verified") == .healthy)
    }

    @Test func legacyFailingMapsToFailing() {
        #expect(SMARTParser.status(fromLegacyStatusString: "Failing") == .failing)
    }

    @Test func legacyUnrecognizedStringMapsToUnknown() {
        #expect(SMARTParser.status(fromLegacyStatusString: "") == .unknown)
        #expect(SMARTParser.status(fromLegacyStatusString: "garbage") == .unknown)
    }

    // MARK: - resolve() - the full NVMe-then-legacy-then-unavailable decision policy

    private static let raw = RawSMARTValues(criticalWarning: 0, temperatureKelvin: 314, percentageUsed: 4,
                                             dataUnitsRead: 1, dataUnitsWritten: 1, powerOnHours: 4694, unsafeShutdowns: 25)

    @Test func resolveWithSuccessfulNVMeReadIgnoresLegacyStatus() {
        // Even if a legacyStatus happens to be supplied, a successful NVMe read wins - SMARTSensor
        // itself never bothers computing legacyStatus in this case, but resolve() must not either.
        let outcome = SMARTParser.resolve(nvme: .success(Self.raw, model: "M", capacityBytes: 1), legacyStatus: "Failing")
        guard case .reading(let info) = outcome else {
            Issue.record("expected a full reading")
            return
        }
        #expect(info.model == "M")
        #expect(info.percentageUsed == 4)
    }

    @Test func resolveStage3FailureNeverFallsBackToLegacyStatus() {
        // A read-time glitch on a controller that DOES support the interface is worth retrying, not
        // masking behind a stale/unrelated legacy status string.
        let outcome = SMARTParser.resolve(nvme: .failed(stage: 3, ioReturn: 0), legacyStatus: "Verified")
        guard case .failure(let error) = outcome, case .transient = error else {
            Issue.record("expected .failure(.transient), got \(outcome)")
            return
        }
    }

    @Test func resolveStage1FailureFallsBackToStatusOnlyReading() {
        // The brief: "NVMe SMART plugin per findings, else status only." Stage 1/2 means the
        // controller doesn't actually support the interface even though something upstream claimed
        // NVMe SMART capability - the legacy status is the right fallback, not .unavailable.
        let outcome = SMARTParser.resolve(nvme: .failed(stage: 1, ioReturn: 0), legacyStatus: "Verified")
        guard case .reading(let info) = outcome else {
            Issue.record("expected a status-only reading, got \(outcome)")
            return
        }
        #expect(info.status == .healthy)
        #expect(info.percentageUsed == nil)
        #expect(info.model == nil)
    }

    @Test func resolveNotFoundFallsBackToStatusOnlyReading() {
        let outcome = SMARTParser.resolve(nvme: .notFound, legacyStatus: "Failing")
        guard case .reading(let info) = outcome else {
            Issue.record("expected a status-only reading, got \(outcome)")
            return
        }
        #expect(info.status == .failing)
    }

    @Test func resolveNotFoundWithNoLegacyStatusIsUnavailable() {
        let outcome = SMARTParser.resolve(nvme: .notFound, legacyStatus: nil)
        guard case .failure(let error) = outcome, case .unavailable = error else {
            Issue.record("expected .failure(.unavailable), got \(outcome)")
            return
        }
    }
}
