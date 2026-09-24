import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct RollupTests {
    private let a = T.app("com.a", "A")
    private let b = T.app("com.b", "B")

    private func store() throws -> HistoryStore {
        try HistoryStore(location: .inMemory, config: T.config(TestClock()))
    }

    @Test func rollsUpCompletedMinuteBucketsOnly() async throws {
        let store = try store()
        try await T.fill(store, from: T.t0, duration: 150) { t, i in
            T.record(at: t, system: [.cpuUsage: Double(i)])
        }
        try await store.maintain(now: T.t0 + 150)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m") == 2)
        let ts0 = T.t0.unixMs
        #expect(try await store.intValue("SELECT n FROM system_1m WHERE ts = \(ts0)") == 12)
        #expect(try await store.intValue("SELECT interval_ms FROM system_1m WHERE ts = \(ts0)") == 60_000)
        #expect(try await store.doubleValue("SELECT cpuUsage FROM system_1m WHERE ts = \(ts0)") == 5.5)     // avg 0…11
        #expect(try await store.doubleValue("SELECT cpuUsage FROM system_1m WHERE ts = \(ts0 + 60_000)") == 17.5)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m WHERE gpuUsage IS NOT NULL") == 0)
    }

    @Test func rollupIsIdempotentAndCompletesLaterBuckets() async throws {
        let store = try store()
        try await T.fill(store, from: T.t0, duration: 90) { t, _ in T.record(at: t, system: [.cpuUsage: 4]) }
        try await store.maintain(now: T.t0 + 90)
        try await store.maintain(now: T.t0 + 90)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m") == 1)
        #expect(try await store.intValue("SELECT SUM(n) FROM system_1m") == 12)

        try await T.fill(store, from: T.t0 + 90, duration: 30) { t, _ in T.record(at: t, system: [.cpuUsage: 8]) }
        try await store.maintain(now: T.t0 + 120)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m") == 2)
        #expect(try await store.doubleValue("SELECT cpuUsage FROM system_1m WHERE ts = \(T.t0.unixMs + 60_000)") == 6)
        #expect(try await store.intValue("SELECT SUM(n) FROM system_1m") == 24)
    }

    @Test func quarterBucketsAreSampleWeightedFromMinutes() async throws {
        let store = try store()
        // Minute 0: 60 samples at 1 s of value 1; minutes 1–14: 12 samples at 5 s of value 10.
        try await T.fill(store, from: T.t0, duration: 60, step: 1) { t, _ in
            T.record(at: t, interval: .seconds(1), system: [.cpuUsage: 1])
        }
        try await T.fill(store, from: T.t0 + 60, duration: 840) { t, _ in T.record(at: t, system: [.cpuUsage: 10]) }
        try await store.maintain(now: T.t0 + 900)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_15m") == 1)
        #expect(try await store.intValue("SELECT n FROM system_15m") == 60 + 14 * 12)
        #expect(try await store.intValue("SELECT interval_ms FROM system_15m") == 900_000)
        let expected = (60.0 * 1 + 168 * 10) / 228
        let got = try #require(try await store.doubleValue("SELECT cpuUsage FROM system_15m"))
        #expect(abs(got - expected) < 1e-9)
    }

    @Test func absentAppsCountAsZero() async throws {
        let store = try store()
        // A in every other sample (cpu 10); B in every sample (cpu 2, memory unknown).
        try await T.fill(store, from: T.t0, duration: 900) { t, i in
            var apps: [(AppIdentity, [AppMetric: Double])] = [(b, [.cpu: 2])]
            if i % 2 == 0 { apps.append((a, [.cpu: 10, .memory: 100])) }
            return T.record(at: t, system: [.cpuUsage: 1], apps: apps)
        }
        try await store.maintain(now: T.t0 + 900)
        let aCPU = "SELECT cpu FROM app_1m JOIN app ON app.id = app_id WHERE key_id = 'com.a' AND ts = \(T.t0.unixMs)"
        #expect(try await store.doubleValue(aCPU) == 5)                                 // 6 × 10 / 12
        #expect(try await store.intValue("SELECT n FROM app_1m LIMIT 1") == 12)
        #expect(try await store.doubleValue("""
            SELECT memory FROM app_1m JOIN app ON app.id = app_id WHERE key_id = 'com.a' AND ts = \(T.t0.unixMs)
            """) == 50)
        #expect(try await store.intValue("""
            SELECT COUNT(*) FROM app_1m JOIN app ON app.id = app_id WHERE key_id = 'com.b' AND memory IS NULL
            """) == 15)
        #expect(try await store.doubleValue("""
            SELECT cpu FROM app_15m JOIN app ON app.id = app_id WHERE key_id = 'com.a'
            """) == 5)
        #expect(try await store.intValue("SELECT n FROM app_15m LIMIT 1") == 180)
    }

    @Test func appOnlyInOneMinuteIsDilutedOverQuarter() async throws {
        let store = try store()
        try await T.fill(store, from: T.t0, duration: 900) { t, i in
            T.record(at: t, system: [.cpuUsage: 1], apps: i < 12 ? [(a, [.cpu: 30])] : [])
        }
        try await store.maintain(now: T.t0 + 900)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_1m") == 1)
        #expect(try await store.doubleValue("SELECT cpu FROM app_15m") == 2)            // 30 / 15
    }
}
