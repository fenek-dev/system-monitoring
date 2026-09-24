import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct CSVExportTests {
    private static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Golden/export-hour.csv")

    private func hourStore() async throws -> HistoryStore {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 3_600, step: 60) { t, i in
            var values: [HistoryMetric: Double] = [.cpuUsage: Double(i) * 1.5, .memUsed: 8e9 + Double(i), .socTemp: 41.25]
            if i % 3 != 0 { values[.netRx] = Double(i * 1_000) }
            return T.record(at: t, interval: .seconds(60), system: values,
                            apps: [(T.app("com.a"), [.cpu: 1])])   // apps are not exported
        }
        return store
    }

    @Test func hourExportMatchesGolden() async throws {
        let store = try await hourStore()
        let url = T.tempDir().appendingPathComponent("export.csv")
        let summary = try await store.exportCSV(range: .hour, end: T.t0 + 3_600, to: url)
        let actual = try String(contentsOf: url, encoding: .utf8)
        if ProcessInfo.processInfo.environment["TELLTALE_RECORD"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try actual.write(to: Self.goldenURL, atomically: true, encoding: .utf8)
        }
        let golden = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        #expect(actual == golden)
        #expect(summary.rows == 60)
        #expect(summary.url == url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(summary.bytes == size)
    }

    @Test func headerIsTimeIntervalThenEveryMetric() async throws {
        let store = try await hourStore()
        let url = T.tempDir().appendingPathComponent("export.csv")
        _ = try await store.exportCSV(range: .hour, end: T.t0 + 3_600, to: url)
        let header = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first.map(String.init)
        #expect(header == (["time", "interval_s"] + HistoryMetric.allCases.map(\.rawValue)).joined(separator: ","))
    }

    /// A forced sample < 1 s after the previous one keeps a distinct timestamp; `interval_s` tells 1 s from 5 s rows.
    @Test func timestampsCarryMillisecondsAndIntervals() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        await store.append(RecordBatch(record: T.record(at: T.t0, system: [.cpuUsage: 1])))
        await store.append(RecordBatch(record: T.record(at: T.t0 + 0.25, interval: .seconds(1), system: [.cpuUsage: 2])))
        await store.append(RecordBatch(record: T.record(at: T.t0 + 1.25, interval: .milliseconds(1_500),
                                                        system: [.cpuUsage: 3])))
        try await store.flush()
        let url = T.tempDir().appendingPathComponent("ms.csv")
        _ = try await store.exportCSV(range: .hour, end: T.t0 + 60, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst()
        #expect(lines.map { $0.split(separator: ",", omittingEmptySubsequences: false).prefix(3).joined(separator: ",") } == [
            "2026-09-21T14:00:00.000Z,5,1.0",
            "2026-09-21T14:00:00.250Z,1,2.0",
            "2026-09-21T14:00:01.250Z,1.5,3.0",
        ])
    }

    @Test func emptyRangeWritesHeaderOnlyAndOverwrites() async throws {
        let store = try await hourStore()
        let url = T.tempDir().appendingPathComponent("export.csv")
        try String(repeating: "stale\n", count: 1_000).write(to: url, atomically: true, encoding: .utf8)
        let summary = try await store.exportCSV(range: .hour, end: T.t0 - 86_400, to: url)
        #expect(summary.rows == 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
        #expect(!text.contains("stale"))
    }

    @Test func weekExportUsesMinuteRollups() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 600) { t, _ in T.record(at: t, system: [.cpuUsage: 2]) }
        try await store.maintain(now: T.t0 + 600)
        let url = T.tempDir().appendingPathComponent("week.csv")
        let summary = try await store.exportCSV(range: .week, end: T.t0 + 600, to: url)
        #expect(summary.rows == 10)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines[1].hasPrefix("2026-09-21T14:00:00.000Z,60,2.0,"))            // a 1 m average covering 60 s
        #expect(lines[2].hasPrefix("2026-09-21T14:01:00.000Z,60,"))
    }

    @Test func failedExportKeepsTheExistingFileAndLeavesNoTemp() async throws {
        let store = try await hourStore()
        let dir = T.tempDir()
        let url = dir.appendingPathComponent("export.csv")
        try "previous export\n".write(to: url, atomically: true, encoding: .utf8)
        try await store.execute("DROP TABLE system_raw")                   // the query fails after the temp exists
        await #expect(throws: (any Error).self) {
            _ = try await store.exportCSV(range: .hour, end: T.t0 + 3_600, to: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "previous export\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["export.csv"])
    }

    @Test func unwritableDestinationThrows() async throws {
        let store = try await hourStore()
        let url = URL(fileURLWithPath: "/nonexistent-telltale-dir/export.csv")
        await #expect(throws: (any Error).self) {
            _ = try await store.exportCSV(range: .hour, end: T.t0 + 3_600, to: url)
        }
    }
}
