import Foundation
import MonitorModel
import os
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

    /// Another connection holds the write lock longer than the 1.5 s busy timeout: the final flush fails,
    /// the batch is dropped and logged, and shutdown returns inside the runtime's 3 s budget.
    @Test func shutdownUnderForeignWriteLockFailsWithinBudget() async throws {
        let url = T.tempDB()
        let other = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        let store = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        await store.append(RecordBatch(record: fullRecord(T.t0)))
        let locked = OSAllocatedUnfairLock(initialState: false)
        let holder = Task { try await other.holdWriteLock(seconds: 2.5) { locked.withLock { $0 = true } } }
        while !locked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }

        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await store.shutdown() }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(1.4))                                  // it did wait for the lock
        #expect(elapsed < .seconds(2.2))                                   // ~1.5 s busy timeout, well under 3 s
        #expect(await store.droppedBatches == 1)
        try await holder.value
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
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

    @Test func unusablePathThrows() throws {
        let dir = T.tempDir()
        let blocker = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        #expect(throws: (any Error).self) {
            _ = try HistoryStore(location: .file(blocker.appendingPathComponent("history.sqlite")))
        }
    }

    /// R-M1: a non-SQLite (or corrupt) file is moved to `history.corrupt-<date>.sqlite` and a fresh store opens,
    /// instead of every launch falling back to memory.
    @Test func corruptFileIsMovedAsideAndRecreated() async throws {
        let url = T.tempDB()
        let garbage = Data(repeating: 0x5A, count: 8_192)
        try garbage.write(to: url)
        let store = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        await store.append(RecordBatch(record: fullRecord(T.t0)))
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 1)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let aside = try #require(siblings.first { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".sqlite") })
        #expect(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(aside)) == garbage)
        #expect(StoreDatabase.corruptName(url, at: T.t0) == "history.corrupt-20260921T140000Z.sqlite")
    }

    /// R-I1 / E-I2: the process died (crash, kill -9, power loss) with episodes open. Its WAL is left behind
    /// un-checkpointed and nothing wrote the closing rows; the next open ends each at the last sample recorded at
    /// or after its start (or at its start when there is none).
    @Test func eventsLeftOpenByACrashAreClosedOnOpen() async throws {
        let url = T.tempDB()
        let thermal = HistoryEvent(kind: .thermalPressure, start: T.t0 + 10, level: .elevated, label: "Thermal")
        let sleep = HistoryEvent(kind: .systemSleep, start: T.t0 + 100, level: .calm, label: "System sleep")
        let closed = HistoryEvent(kind: .samplingPaused, start: T.t0, end: T.t0 + 5, level: .calm, label: "Paused")
        let crashed = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        for i in 0..<12 { await crashed.append(RecordBatch(record: fullRecord(T.t0 + Double(i) * 5))) }
        await crashed.append(RecordBatch(events: [thermal, sleep, closed]))
        try await crashed.flush()                         // no shutdown(): the process is gone, WAL not checkpointed
        #expect(try await crashed.intValue("SELECT COUNT(*) FROM event WHERE \"end\" IS NULL") == 2)

        let relaunched = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        let events = try await relaunched.events(in: DateInterval(start: T.t0 - 60, duration: 3_600))
        #expect(events.first { $0.id == thermal.id }?.end == T.t0 + 55)       // last sample at/after its start
        #expect(events.first { $0.id == sleep.id }?.end == sleep.start)       // no sample after it: zero length
        #expect(events.first { $0.id == closed.id }?.end == closed.end)       // closed events untouched
        #expect(try await relaunched.intValue("SELECT COUNT(*) FROM event WHERE \"end\" IS NULL") == 0)
    }

    /// R-M2: SQLITE_BUSY past the busy timeout is retried after a backoff; the batch lands once the lock is free.
    @Test func busyWriteIsRetriedWithBackoff() async throws {
        let url = T.tempDB()
        let other = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        var config = T.config(TestClock())
        config.busyRetryDelays = [.milliseconds(100), .milliseconds(100)]
        let store = try HistoryStore(location: .file(url), config: config)
        for i in 0..<3 { await store.append(RecordBatch(record: fullRecord(T.t0 + Double(i) * 5))) }
        let locked = OSAllocatedUnfairLock(initialState: false)
        let holder = Task { try await other.holdWriteLock(seconds: 2) { locked.withLock { $0 = true } } }
        while !locked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }

        try await store.flush()                                            // 1st attempt busy at 1.5 s, 2nd waits
        try await holder.value
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 3)
        #expect(await store.droppedBatches == 0)
        #expect(await store.carriedRecordCount == 0)
    }

    /// R-M2: still busy after every retry, the batch is kept and written ahead of the next flush (never dropped).
    @Test func busyBatchIsCarriedToTheNextFlush() async throws {
        let url = T.tempDB()
        let other = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        var config = T.config(TestClock())
        config.busyRetryDelays = []
        let store = try HistoryStore(location: .file(url), config: config)
        let open = HistoryEvent(kind: .thermalPressure, start: T.t0, level: .elevated, label: "Thermal")
        await store.append(RecordBatch(record: fullRecord(T.t0), events: [open]))
        let locked = OSAllocatedUnfairLock(initialState: false)
        let holder = Task { try await other.holdWriteLock(seconds: 1.8) { locked.withLock { $0 = true } } }
        while !locked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }

        await #expect(throws: (any Error).self) { try await store.flush() }
        #expect(await store.carriedRecordCount == 1)
        try await holder.value
        var ended = open
        ended.end = T.t0 + 5
        await store.append(RecordBatch(record: fullRecord(T.t0 + 5), events: [ended]))
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 2)
        #expect(try await store.intValue("SELECT \"end\" FROM event") == Int((T.t0 + 5).unixMs))   // update kept its order
        #expect(await store.droppedBatches == 0)
    }

    /// R-M3: quit leaves no WAL behind, and the writer truncates the WAL to 8 MB after checkpoints.
    @Test func shutdownTruncatesTheWAL() async throws {
        let url = T.tempDB()
        let store = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        #expect(try await store.writerInt("PRAGMA journal_size_limit") == 8_388_608)
        for i in 0..<50 { await store.append(RecordBatch(record: fullRecord(T.t0 + Double(i) * 5))) }
        try await store.flush()
        let wal = url.path + "-wal"
        #expect((try FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int ?? 0) > 0)
        try await store.shutdown()
        #expect(try FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int == 0)
    }
}
