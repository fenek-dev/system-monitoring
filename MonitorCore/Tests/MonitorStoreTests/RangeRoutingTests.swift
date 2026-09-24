import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

/// Same period stored with a different value per level: raw = 1, 1 m = 2, 15 m = 3.
@Suite struct RangeRoutingTests {
    private let end = T.t0

    private func seeded() async throws -> HistoryStore {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let from = (end - 7_200).unixMs, to = end.unixMs
        try await store.execute("""
            WITH RECURSIVE s(ts) AS (SELECT \(from) UNION ALL SELECT ts + 5000 FROM s WHERE ts + 5000 < \(to))
            INSERT INTO system_raw(ts, interval_ms, cpuUsage) SELECT ts, 5000, 1 FROM s
            """)
        try await store.execute("""
            WITH RECURSIVE s(ts) AS (SELECT \(from) UNION ALL SELECT ts + 60000 FROM s WHERE ts + 60000 < \(to - 1_800_000))
            INSERT INTO system_1m(ts, n, interval_ms, cpuUsage) SELECT ts, 12, 60000, 2 FROM s
            """)
        try await store.execute("""
            WITH RECURSIVE s(ts) AS (SELECT \(from) UNION ALL SELECT ts + 900000 FROM s WHERE ts + 900000 < \(to - 3_600_000))
            INSERT INTO system_15m(ts, n, interval_ms, cpuUsage) SELECT ts, 180, 900000, 3 FROM s
            """)
        return store
    }

    @Test func rangeMapsToLevel() {
        #expect(Level.forRange(.live) == .raw)
        #expect(Level.forRange(.hour) == .raw)
        #expect(Level.forRange(.day) == .raw)
        #expect(Level.forRange(.week) == .minute)
        #expect(Level.forRange(.month) == .quarter)
    }

    @Test(arguments: [HistoryRange.live, .hour, .day])
    func shortRangesReadRaw(range: HistoryRange) async throws {
        let store = try await seeded()
        let values = try await store.series([.cpuUsage], range: range, end: end)[.cpuUsage]?.compactMap(\.value) ?? []
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0 == 1 })
    }

    @Test func weekReadsMinuteRollupsWithRawTail() async throws {
        let store = try await seeded()
        let points = try #require(try await store.series([.cpuUsage], range: .week, end: end)[.cpuUsage])
        #expect(points.count == 7 * 48)                                     // 7 d / 30 min
        let present = points.filter { $0.value != nil }
        #expect(present.map(\.time) == [end - 7_200, end - 5_400, end - 3_600, end - 1_800])
        #expect(present.map(\.value) == [2, 2, 2, 1])                       // last 30 min not rolled up yet → raw
    }

    @Test func monthReadsQuarterRollupsWithRawTail() async throws {
        let store = try await seeded()
        let points = try #require(try await store.series([.cpuUsage], range: .month, end: end, bucket: .seconds(3_600))[.cpuUsage])
        let present = points.filter { $0.value != nil }
        #expect(present.map(\.time) == [end - 7_200, end - 3_600])
        #expect(present.map(\.value) == [3, 1])
        let byDefault = try #require(try await store.series([.cpuUsage], range: .month, end: end)[.cpuUsage])
        #expect(byDefault.count == 360)                                     // 30 d / 2 h
        #expect(byDefault.last?.value == 2)                                 // (720 × 3 + 720 × 1) / 1440
    }

    @Test func customBucketsRoundToLevelResolution() async throws {
        let store = try await seeded()
        let week = try #require(try await store.series([.cpuUsage], range: .week, end: end, bucket: .seconds(90))[.cpuUsage])
        #expect(week.count == 7 * 86_400 / 120)                            // 90 s → 2 min on the 1 m level
        #expect(week[1].time.timeIntervalSince(week[0].time) == 120)
        let hour = try #require(try await store.series([.cpuUsage], range: .hour, end: end, bucket: .milliseconds(15_400))[.cpuUsage])
        #expect(hour.count == 240)                                          // 15.4 s → 15 s on raw
    }

    @Test func dayRangeWithPastEndReadsRollupsForTheExpiredPart() async throws {
        let clock = TestClock()
        let store = try HistoryStore(location: .inMemory, config: T.config(clock))
        let start = T.t0 - 36 * 3_600
        try await store.execute("""
            WITH RECURSIVE s(ts) AS (SELECT \(start.unixMs) UNION ALL SELECT ts + 5000 FROM s WHERE ts + 5000 < \((T.t0 - 12 * 3_600).unixMs))
            INSERT INTO system_raw(ts, interval_ms, cpuUsage) SELECT ts, 5000, 7 FROM s
            """)
        try await store.maintain(now: T.t0)                                 // raw older than 24 h → rolled, then deleted
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw WHERE ts < \((T.t0 - 86_400).unixMs)") == 0)
        let points = try #require(try await store.series([.cpuUsage], range: .day, end: T.t0 - 12 * 3_600)[.cpuUsage])
        #expect(points.count == 288)
        #expect(points.allSatisfy { $0.value == 7 })                        // no hole where raw expired
    }

    @Test func bucketFinerThanLevelIsClamped() async throws {
        let store = try await seeded()
        let points = try #require(try await store.series([.cpuUsage], range: .week, end: end, bucket: .seconds(5))[.cpuUsage])
        #expect(points.count == 7 * 1_440)                                  // 1 min, not 5 s
    }
}
