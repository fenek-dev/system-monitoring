import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct RetentionTests {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    @Test func deletesRowsPastEachLevelsRetention() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let now = T.t0
        let a = T.app("com.a")
        for offset in [-25 * hour, -1 * hour] {
            await store.append(RecordBatch(record: T.record(at: now + offset, system: [.cpuUsage: 1], apps: [(a, [.cpu: 1])])))
        }
        try await store.flush()
        let aID = try #require(try await store.intValue("SELECT id FROM app"))
        for (table, offsets) in [("1m", [-8 * day, -6 * day]), ("15m", [-31 * day, -29 * day])] {
            for offset in offsets {
                let ts = (now + offset).unixMs
                try await store.execute("INSERT INTO system_\(table)(ts, n, interval_ms, cpuUsage) VALUES (\(ts), 1, 5000, 1)")
                try await store.execute("INSERT INTO app_\(table)(ts, app_id, n, cpu) VALUES (\(ts), \(aID), 1, 1)")
            }
        }
        try await store.maintain(now: now)

        let rawCutoff = (now - day).unixMs
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 1)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw WHERE ts < \(rawCutoff)") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw WHERE ts < \(rawCutoff)") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw") == 1)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m WHERE ts < \((now - 7 * day).unixMs)") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_1m WHERE ts < \((now - 7 * day).unixMs)") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m WHERE ts = \((now - 6 * day).unixMs)") == 1)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_15m WHERE ts < \((now - 30 * day).unixMs)") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_15m WHERE ts < \((now - 30 * day).unixMs)") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_15m WHERE ts = \((now - 29 * day).unixMs)") == 1)
    }

    @Test func exactBoundariesKeepCutoffAndDeleteOneMillisecondOlder() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let now = T.t0.unixMs
        for (level, retention) in [(Level.raw, day), (.minute, 7 * day), (.quarter, 30 * day)] {
            let cutoff = now - Int64(retention * 1_000)
            for ts in [cutoff - 1, cutoff] {
                let cols = level == .raw ? "ts, interval_ms" : "ts, n, interval_ms"
                let vals = level == .raw ? "\(ts), 5000" : "\(ts), 1, 5000"
                try await store.execute("INSERT INTO \(level.systemTable)(\(cols)) VALUES (\(vals))")
            }
        }
        let eventCutoff = T.t0 - 30 * day
        await store.append(RecordBatch(events: [
            HistoryEvent(kind: .systemSleep, start: eventCutoff - 60, end: eventCutoff, label: "kept"),
            HistoryEvent(kind: .systemSleep, start: eventCutoff - 60, end: eventCutoff - 0.001, label: "gone"),
        ]))
        try await store.flush()
        // Roll-ups would add rows; this test inspects retention only, so run it directly.
        try await store.runRetention(now: T.t0)
        for (level, retention) in [(Level.raw, day), (.minute, 7 * day), (.quarter, 30 * day)] {
            let cutoff = now - Int64(retention * 1_000)
            #expect(try await store.intValue("SELECT COUNT(*) FROM \(level.systemTable) WHERE ts = \(cutoff)") == 1)
            #expect(try await store.intValue("SELECT COUNT(*) FROM \(level.systemTable) WHERE ts = \(cutoff - 1)") == 0)
        }
        #expect(try await store.stringValue("SELECT group_concat(label) FROM event") == "kept")
    }

    @Test func levelCrossesAtRetentionBoundaries() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        #expect(await store.level(forIntervalStart: T.t0 - day) == .raw)
        #expect(await store.level(forIntervalStart: T.t0 - day - 0.001) == .minute)
        #expect(await store.level(forIntervalStart: T.t0 - 7 * day) == .minute)
        #expect(await store.level(forIntervalStart: T.t0 - 7 * day - 0.001) == .quarter)
        #expect(await store.level(for: .day, end: T.t0) == .raw)
        #expect(await store.level(for: .day, end: T.t0 - 1) == .minute)   // window starts 24 h + 1 s ago
        #expect(await store.level(for: .hour, end: T.t0 - 8 * day) == .quarter)
    }

    @Test func rawRowsAreRolledUpBeforeTheyExpire() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let start = T.t0 - 2 * day
        try await T.fill(store, from: start, duration: 120) { t, _ in T.record(at: t, system: [.cpuUsage: 7]) }
        try await store.maintain(now: T.t0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m") == 2)
        #expect(try await store.doubleValue("SELECT AVG(cpuUsage) FROM system_1m") == 7)
    }

    @Test func eventsExpireAfterThirtyDaysByEnd() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let now = T.t0
        let events = [
            HistoryEvent(kind: .systemSleep, start: now - 40 * day, end: now - 31 * day, label: "old"),
            HistoryEvent(kind: .systemSleep, start: now - 40 * day, end: now - 29 * day, label: "long"),
            HistoryEvent(kind: .samplingPaused, start: now - 31 * day, end: nil, label: "open-old"),
            HistoryEvent(kind: .samplingPaused, start: now - day, end: nil, label: "open-new"),
        ]
        await store.append(RecordBatch(events: events))
        try await store.maintain(now: now)
        #expect(try await store.stringValue("SELECT group_concat(label, ',') FROM (SELECT label FROM event ORDER BY label)")
            == "long,open-new")
    }

    @Test func unreferencedAppsArePruned() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        let gone = T.app("com.gone"), kept = T.app("com.kept"), flagged = T.app("com.flagged")
        await store.append(RecordBatch(record: T.record(at: T.t0 - 40 * day, apps: [(gone, [.cpu: 1]), (flagged, [.cpu: 1])])))
        await store.append(RecordBatch(record: T.record(at: T.t0 - hour, apps: [(kept, [.cpu: 1])]),
                                       events: [HistoryEvent(kind: .runawayApp, start: T.t0 - hour, app: flagged)]))
        try await store.maintain(now: T.t0)
        #expect(try await store.stringValue("SELECT group_concat(key_id, ',') FROM (SELECT key_id FROM app ORDER BY key_id)")
            == "com.flagged,com.kept")
    }

    @Test func incrementalVacuumReturnsFreedPages() async throws {
        let store = try HistoryStore(location: .file(T.tempDB()), config: T.config(TestClock()))
        let apps = (0..<25).map { T.app("com.app\($0)") }
        try await T.fill(store, from: T.t0, duration: 6 * hour) { t, i in
            T.record(at: t, system: [.cpuUsage: Double(i), .memUsed: 1e9],
                     apps: apps.map { ($0, [.cpu: 1, .memory: 1e8, .netRx: 10]) })
        }
        let before = try #require(try await store.intValue("PRAGMA page_count"))
        try await store.maintain(now: T.t0 + 40 * day)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_15m") == 0)
        #expect(try await store.writerInt("PRAGMA freelist_count") == 0)
        let after = try #require(try await store.writerInt("PRAGMA page_count"))
        #expect(after < before / 4)
    }
}
