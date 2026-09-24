import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct WriterTests {
    @Test func appendBuffersUntilFlush() async throws {
        let clock = TestClock()
        let store = try HistoryStore(location: .inMemory, config: T.config(clock))
        for i in 0..<3 {
            await store.append(RecordBatch(record: T.record(at: T.t0 + Double(i) * 5, system: [.cpuUsage: 10])))
        }
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 3)
        try await store.flush()   // empty flush is a no-op
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 3)
    }

    @Test func flushesWhenBufferReachesMaxRecords() async throws {
        let clock = TestClock()
        let store = try HistoryStore(location: .inMemory, config: T.config(clock, flushMaxRecords: 5))
        for i in 0..<4 { await store.append(RecordBatch(record: T.record(at: T.t0 + Double(i)))) }
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        await store.append(RecordBatch(record: T.record(at: T.t0 + 4)))
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 5)
    }

    @Test func flushesWhenIntervalElapsed() async throws {
        let clock = TestClock()
        let store = try HistoryStore(location: .inMemory, config: T.config(clock))
        await store.append(RecordBatch(record: T.record(at: T.t0)))
        clock.advance(29)
        await store.append(RecordBatch(record: T.record(at: T.t0 + 29)))
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        clock.advance(1)
        await store.append(RecordBatch(record: T.record(at: T.t0 + 30)))
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 3)
    }

    @Test func writesSystemValuesIntervalAndNulls() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        await store.append(RecordBatch(record: T.record(at: T.t0, interval: .milliseconds(1_500),
                                                        system: [.cpuUsage: 42.5, .memUsed: 8e9])))
        try await store.flush()
        let ts = Int(T.t0.timeIntervalSince1970 * 1000)
        #expect(try await store.intValue("SELECT ts FROM system_raw") == ts)
        #expect(try await store.intValue("SELECT interval_ms FROM system_raw") == 1_500)
        #expect(try await store.doubleValue("SELECT cpuUsage FROM system_raw") == 42.5)
        #expect(try await store.doubleValue("SELECT memUsed FROM system_raw") == 8e9)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw WHERE gpuUsage IS NULL") == 1)
    }

    @Test func appsAreUpsertedAndOtherRowStored() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let safari = T.app("com.apple.Safari", "Safari")
        var renamed = safari
        renamed.displayName = "Safari Technology"
        await store.append(RecordBatch(record: T.record(at: T.t0, apps: [(safari, [.cpu: 12]), (T.other, [.cpu: 3])])))
        await store.append(RecordBatch(record: T.record(at: T.t0 + 5, apps: [(renamed, [.cpu: 14, .memory: 1e8])])))
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM app") == 2)
        #expect(try await store.stringValue("SELECT name FROM app WHERE key_id = 'com.apple.Safari'") == "Safari Technology")
        #expect(try await store.stringValue("SELECT key_kind FROM app WHERE key_id = 'other'") == "other")
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw") == 3)
        #expect(try await store.doubleValue("""
            SELECT SUM(cpu) FROM app_raw JOIN app ON app.id = app_raw.app_id WHERE key_id = 'com.apple.Safari'
            """) == 26)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw WHERE memory IS NULL") == 2)
    }

    @Test func eventsAreInsertedThenUpdated() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let app = T.app("com.x", "X")
        var event = HistoryEvent(kind: .runawayApp, start: T.t0, level: .elevated, app: app, metric: .cpu,
                                 peak: 120, label: "X")
        await store.append(RecordBatch(events: [event]))
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM event WHERE \"end\" IS NULL") == 1)

        event.end = T.t0 + 600
        event.peak = 180
        event.level = .critical
        await store.append(RecordBatch(record: T.record(at: T.t0 + 600), events: [event]))
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM event") == 1)
        #expect(try await store.intValue("SELECT \"end\" FROM event") == Int((T.t0 + 600).timeIntervalSince1970 * 1000))
        #expect(try await store.doubleValue("SELECT peak FROM event") == 180)
        #expect(try await store.intValue("SELECT level FROM event") == 2)
        #expect(try await store.stringValue("SELECT metric FROM event") == "cpu")
        #expect(try await store.intValue("SELECT COUNT(*) FROM event JOIN app ON app.id = event.app_id") == 1)
    }

    @Test func appendWithoutRecordOrEventsWritesNothing() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock(), flushMaxRecords: 1))
        await store.append(RecordBatch())
        try await store.flush()
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
    }
}
