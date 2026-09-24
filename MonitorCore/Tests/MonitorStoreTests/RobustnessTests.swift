import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct RobustnessTests {
    private let apps = (0..<25).map { T.app("com.app\($0)") }

    private func fullRecord(_ t: Date) -> HistoryRecord {
        var system: [HistoryMetric: Double] = [:]
        for m in HistoryMetric.allCases { system[m] = 1 }
        return T.record(at: t, system: system, apps: apps.map { ($0, [.cpu: 1, .memory: 1e8, .netRx: 5, .energy: 0.2]) })
    }

    /// Termination path (§4): no flushSync; shutdown awaits `flush()`, which must also wait for an
    /// append-triggered flush already in flight.
    @Test func flushAwaitsInFlightWritesAndPersistsEverything() async throws {
        let store = try HistoryStore(location: .file(T.tempDB()), config: T.config(TestClock(), flushMaxRecords: 5))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask { await store.append(RecordBatch(record: self.fullRecord(T.t0 + Double(i) * 5))) }
            }
            group.addTask { try? await store.flush() }
        }
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 12)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw") == 12 * 25)
    }

    @Test func shutdownStopsMaintenanceAndFlushes() async throws {
        let clock = TestClock()
        let store = try HistoryStore(location: .file(T.tempDB()),
                                     config: T.config(clock, maintenanceInterval: .milliseconds(20)))
        let deadline = ContinuousClock.now + .seconds(5)
        while await store.maintenanceRuns < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await store.maintenanceRuns >= 2)
        for i in 0..<7 { await store.append(RecordBatch(record: fullRecord(T.t0 + Double(i) * 5))) }
        try await store.shutdown()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 7)
        let runs = await store.maintenanceRuns
        try await Task.sleep(for: .milliseconds(200))                        // ~10 timer periods
        #expect(await store.maintenanceRuns == runs)
    }

    @Test func appendAfterShutdownIsDroppedNotBuffered() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        await store.append(RecordBatch(record: fullRecord(T.t0)))
        try await store.shutdown()
        await store.append(RecordBatch(record: fullRecord(T.t0 + 5), events: [HistoryEvent(start: T.t0)]))
        #expect(await store.pendingRecordCount == 0)
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 1)
        #expect(try await store.intValue("SELECT COUNT(*) FROM event") == 0)
    }

    @Test func flushOf120BufferedRecordsIsFast() async throws {
        let store = try HistoryStore(location: .file(T.tempDB()), config: T.config(TestClock(), flushMaxRecords: 1_000))
        for i in 0..<120 { await store.append(RecordBatch(record: fullRecord(T.t0 + Double(i)))) }
        let elapsed = try await ContinuousClock().measure { try await store.flush() }
        #expect(elapsed < .seconds(3))
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 120)
    }

    @Test func writeFailureDropsTheWholeBatch() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock(), flushMaxRecords: 2))
        try await store.execute("""
            CREATE TRIGGER fail BEFORE INSERT ON system_raw WHEN NEW.ts = \((T.t0 + 5).unixMs)
            BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END
            """)
        await store.append(RecordBatch(record: fullRecord(T.t0)))
        await store.append(RecordBatch(record: fullRecord(T.t0 + 5)))       // count flush fails → logged, dropped
        await store.writesSettled()
        #expect(await store.pendingRecordCount == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw") == 0)   // one transaction: nothing partial

        await store.append(RecordBatch(record: fullRecord(T.t0 + 5)))
        await #expect(throws: (any Error).self) { try await store.flush() }  // explicit flush reports it
        #expect(await store.pendingRecordCount == 0)

        await store.append(RecordBatch(record: fullRecord(T.t0 + 10)))
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 1)
    }

    @Test func newerUserVersionIsMovedAside() async throws {
        let url = T.tempDB()
        do {
            let old = try HistoryStore(location: .file(url), config: T.config(TestClock()))
            await old.append(RecordBatch(record: fullRecord(T.t0)))
            try await old.flush()
            try await old.execute("PRAGMA user_version = 99")
        }
        let store = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        #expect(try await store.intValue("PRAGMA user_version") == Schema.version)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("history.sqlite.newer-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
    }

    @Test func unusablePathsThrow() throws {
        let dir = T.tempDir()
        let blocker = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        #expect(throws: (any Error).self) {
            _ = try HistoryStore(location: .file(blocker.appendingPathComponent("history.sqlite")))
        }
        let garbage = dir.appendingPathComponent("garbage.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: garbage)
        #expect(throws: (any Error).self) { _ = try HistoryStore(location: .file(garbage)) }
    }
}
