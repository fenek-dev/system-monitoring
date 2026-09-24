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
}
