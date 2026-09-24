import Foundation
import Testing
@testable import MonitorSensors

@Suite struct DiskIOParseTests {
    private func loadFixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/W6d"))
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func parsesRealCapturedStatisticsDump() throws {
        let raw = try loadFixture("disk-io-statistics")
        let counters = DiskIOParser.parseStatistics(raw)
        #expect(counters.readOps == 120_191_932)
        #expect(counters.writeOps == 150_107_541)
        #expect(counters.readBytes == 1_402_699_673_600)
        #expect(counters.writeBytes == 3_126_319_808_512)
    }

    @Test func missingKeysDefaultToZero() {
        let counters = DiskIOParser.parseStatistics([:])
        #expect(counters == .init(readOps: 0, writeOps: 0, readBytes: 0, writeBytes: 0))
    }

    @Test func ignoresUnrelatedKeys() {
        let counters = DiskIOParser.parseStatistics(["Retries (Read)": 3, "Errors (Write)": 1])
        #expect(counters == .init(readOps: 0, writeOps: 0, readBytes: 0, writeBytes: 0))
    }

    @Test func nonNumericValuesDoNotCrashAndDefaultToZero() {
        let counters = DiskIOParser.parseStatistics(["Operations (Read)": "garbage", "Bytes (Write)": NSNull()])
        #expect(counters.readOps == 0)
        #expect(counters.writeBytes == 0)
    }

    @Test func largeCountersRoundTripAsUInt64() {
        // A near-UInt64-max byte counter (implausible, but the parser must not trap or truncate).
        let huge = NSNumber(value: UInt64.max - 1)
        let counters = DiskIOParser.parseStatistics(["Bytes (Read)": huge])
        #expect(counters.readBytes == UInt64.max - 1)
    }
}
