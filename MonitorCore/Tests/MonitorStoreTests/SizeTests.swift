import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

/// Database size (rulings R-I2, R-I3): rollups keep only threshold-passing apps plus `other`, a size guard prunes
/// the oldest raw early, and the in-memory fallback keeps short retention.
@Suite struct SizeTests {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let big = T.app("com.big")
    private let idle = T.app("com.idle")
    private let chatty = T.app("com.chatty")
    private let blip = T.app("com.blip")
    private let gpu = T.app("com.gpu")

    private func appRows(_ store: HistoryStore, _ table: String, at ts: Date) async throws -> String? {
        try await store.stringValue("""
            SELECT group_concat(key_id, ',') FROM (SELECT key_id FROM \(table) JOIN app ON app.id = app_id
            WHERE ts = \(ts.unixMs) ORDER BY key_id)
            """)
    }

    private func otherValue(_ store: HistoryStore, _ table: String, _ column: String, at ts: Date) async throws -> Double? {
        try await store.doubleValue("""
            SELECT \(column) FROM \(table) JOIN app ON app.id = app_id WHERE key_kind = 'other' AND ts = \(ts.unixMs)
            """)
    }

    /// 1 m and 15 m buckets keep an app only when its bucket average passes a `RecordConfig` threshold; the rest
    /// (and a one-sample spike that averages below it) fold into `other`, whose values are the per-metric sums.
    @Test func rollupsKeepThresholdPassingAppsAndFoldTheRest() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 15 * 60) { t, i in
            T.record(at: t, apps: [
                (big, [.cpu: 5]),
                (idle, [.cpu: 0.1, .memory: 1e6]),
                (chatty, [.netRx: 100]),
                (blip, [.cpu: i % 12 == 0 ? 3 : 0]),                        // avg 0.25 % < 0.5 %
                (gpu, [.gpu: i % 12 == 0 ? 1 : 0]),                         // any GPU counts
                (T.other, [.cpu: 0.2]),
            ])
        }
        try await store.maintain(now: T.t0 + 15 * 60)
        #expect(try await appRows(store, "app_1m", at: T.t0) == "com.big,com.gpu,other")
        let minuteOther = try #require(try await otherValue(store, "app_1m", "cpu", at: T.t0))
        #expect(abs(minuteOther - 0.55) < 1e-9)                                       // idle 0.1 + blip 0.25 + other 0.2
        #expect(try await otherValue(store, "app_1m", "netRx", at: T.t0) == 100)
        #expect(try await otherValue(store, "app_1m", "memory", at: T.t0) == 1e6)
        #expect(try await appRows(store, "app_15m", at: T.t0) == "com.big,com.gpu,other")
        let quarter = try #require(try await otherValue(store, "app_15m", "cpu", at: T.t0))
        #expect(abs(quarter - 0.55) < 1e-9)

        // Σ over apps is unchanged by the fold (shares still sum to the whole).
        let shares = try await store.appShares(at: T.t0 + 30, metric: .cpu, range: .week, limit: 10)
        #expect(abs(shares.reduce(0) { $0 + $1.value } - 5.55) < 1e-9)
    }

    /// The newest bucket is recomputed every pass; folding it again must not count folded apps twice.
    @Test func foldIsIdempotentOnTheRecomputedBucket() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 60) { t, _ in
            T.record(at: t, apps: [(big, [.cpu: 5]), (idle, [.cpu: 0.1])])
        }
        try await store.maintain(now: T.t0 + 60)
        try await store.maintain(now: T.t0 + 60)
        try await store.maintain(now: T.t0 + 70)
        #expect(try await appRows(store, "app_1m", at: T.t0) == "com.big,other")
        #expect(try await otherValue(store, "app_1m", "cpu", at: T.t0) == 0.1)
    }

    @Test func noThresholdsKeepsEveryApp() async throws {
        var config = T.config(TestClock())
        config.rollupThresholds = nil
        let store = try HistoryStore(location: .inMemory, config: config)
        try await T.fill(store, from: T.t0, duration: 60) { t, _ in
            T.record(at: t, apps: [(big, [.cpu: 5]), (idle, [.cpu: 0.1])])
        }
        try await store.maintain(now: T.t0 + 60)
        #expect(try await appRows(store, "app_1m", at: T.t0) == "com.big,com.idle")
    }

    /// Guard with a small injected cap: the oldest raw goes early (already rolled up), the last hour never does,
    /// and ranges over the pruned span read 1 m rollups instead of a raw gap.
    @Test func sizeGuardPrunesOldestRawButNeverTheLastHour() async throws {
        let clock = TestClock()
        var config = T.config(clock)
        config.sizeCapBytes = 2 << 20
        let url = T.tempDB()
        let store = try HistoryStore(location: .file(url), config: config)
        let apps = (0..<25).map { T.app("com.app\($0)") }
        try await T.fill(store, from: T.t0, duration: 3 * hour) { t, i in
            T.record(at: t, system: [.cpuUsage: Double(i % 7) + 0.5, .memUsed: 1e9 + Double(i)],
                     apps: apps.map { ($0, [.cpu: 1.5, .memory: 3e8 + Double(i)]) })
        }
        let before = try #require(try await store.intValue("PRAGMA page_count"))
        let now = T.t0 + 3 * hour
        clock.set(now)
        try await store.maintain(now: now)

        #expect(await store.sizeGuardRuns == 1)
        let keepFrom = (now - hour).unixMs
        let oldest = try #require(try await store.intValue("SELECT MIN(ts) FROM system_raw"))
        #expect(oldest > T.t0.unixMs)
        #expect(oldest <= keepFrom)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw WHERE ts >= \(keepFrom)") == 720)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m") == 180)          // rollups kept
        let pageSize = try #require(try await store.intValue("PRAGMA page_size"))
        let after = try #require(try await store.writerInt("PRAGMA page_count"))
        #expect(after < before)
        #expect(after * pageSize <= 2 << 20 || oldest == keepFrom)

        // 24H over the pruned span reads 1 m rollups (plus the raw tail), not a gap.
        #expect(await store.level(forIntervalStart: T.t0) == .minute)
        #expect(await store.level(forIntervalStart: now - 30 * 60) == .raw)
        let series = try #require(try await store.series([.cpuUsage], range: .day, end: now)[.cpuUsage])
        let covered = series.filter { $0.time >= T.t0 && $0.time < now }
        #expect(!covered.isEmpty && covered.allSatisfy { $0.value != nil })

        // A later pass (or a relaunch) under the cap prunes nothing more and still routes around the pruned span.
        let reopened = try HistoryStore(location: .file(url), config: T.config(clock))
        try await reopened.maintain(now: now)
        #expect(await reopened.sizeGuardRuns == 0)
        #expect(await reopened.level(forIntervalStart: T.t0) == .minute)
    }

    /// R-I3: the in-memory fallback keeps raw 1 h, 1 m for 24 h, 15 m for 7 d.
    @Test func inMemoryFallbackUsesShortRetention() async throws {
        let clock = TestClock()
        var config = StoreConfig.inMemoryFallback()
        config.maintenanceInterval = .zero
        config.now = { clock.now }
        #expect(config.rawRetention == .seconds(3_600))
        #expect(config.minuteRetention == .seconds(86_400))
        #expect(config.quarterRetention == .seconds(7 * 86_400))
        let store = try HistoryStore(location: .inMemory, config: config)
        for age in [2 * hour, 30 * hour, 8 * day] {
            await store.append(RecordBatch(record: T.record(at: T.t0 - age, system: [.cpuUsage: 1],
                                                            apps: [(big, [.cpu: 5])])))
        }
        await store.append(RecordBatch(record: T.record(at: T.t0 - 60, system: [.cpuUsage: 1])))
        try await store.maintain(now: T.t0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_raw") == 1)       // 2 h old: rolled up, gone
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_1m") == 2)        // 60 s and 2 h; 30 h gone
        #expect(try await store.intValue("SELECT COUNT(*) FROM system_15m") == 3)       // 8 d gone
        #expect(await store.level(forIntervalStart: T.t0 - 2 * hour) == .minute)
        #expect(await store.level(forIntervalStart: T.t0 - 2 * day) == .quarter)
    }

    /// R-I3 size target (< 10 MB): a full steady state at measured row shapes (28 apps per sample; 32 per 1 m and
    /// 36 per 15 m bucket after the fold), UI closed (5 s raw); and with the dashboard open all hour (1 s raw), where
    /// the guard's 10 MB cap trims raw older than 15 min.
    @Test func inMemoryFallbackStaysUnderTenMegabytes() async throws {
        for rawStep in [5, 1] {
            let clock = TestClock()
            var config = StoreConfig.inMemoryFallback()
            config.maintenanceInterval = .zero
            config.now = { clock.now }
            let store = try HistoryStore(location: .inMemory, config: config)
            let now = T.t0.unixMs
            try await store.execute(Self.steadyState(now: now, rawStep: rawStep))
            let filled = try #require(try await store.intValue("SELECT (SELECT page_count FROM pragma_page_count) * (SELECT page_size FROM pragma_page_size)"))
            try await store.maintain(now: T.t0)
            let bytes = try #require(try await store.writerInt("SELECT (SELECT page_count FROM pragma_page_count) * (SELECT page_size FROM pragma_page_size)"))
            print("in-memory fallback, raw every \(rawStep) s: filled \(filled >> 10) KB → after maintenance \(bytes >> 10) KB")
            #expect(bytes < 10 << 20)
        }
    }

    /// SQL filling raw for the last hour, 1 m for 24 h and 15 m for 7 d. Value shapes follow a real dev database
    /// (3 h of use; about 67 B per raw app row, 70 B per 1 m app row with its index): three quarters of the
    /// system metrics set (fans, battery… NULL), app CPU/energy/disk fractional, memory whole bytes, GPU and
    /// network 0.
    private static func steadyState(now: Int64, rawStep: Int) -> String {
        let sys = HistoryMetric.allCases.map { Schema.quoted($0.rawValue) }
        let app = AppMetric.allCases.map { Schema.quoted($0.rawValue) }
        let sysValues = sys.indices.map { $0 % 4 != 3 ? "(i % 97) * 1.37 + \($0).123" : "NULL" }.joined(separator: ", ")
        let appValues = AppMetric.allCases.map { m -> String in
            switch m {
            case .cpu, .energy: "(i % 89) * 0.71 + a * 0.013 + 0.5"
            case .memory: "a * 10000019 + i"
            case .diskRead, .diskWrite: "CASE WHEN (i + a) % 3 = 0 THEN (i % 89) * 2.71 + 0.5 ELSE 0 END"
            case .gpu, .netRx, .netTx: "0"
            }
        }.joined(separator: ", ")
        func level(_ system: String, _ appTable: String, n: Bool, step: Int64, count: Int64, apps: Int) -> String {
            let first = (now / step) * step - count * step
            return """
                WITH RECURSIVE s(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM s WHERE i < \(count - 1))
                INSERT INTO \(system)(ts\(n ? ", n" : ""), interval_ms, \(sys.joined(separator: ", ")))
                SELECT \(first) + i * \(step)\(n ? ", 12" : ""), \(step), \(sysValues) FROM s;
                WITH RECURSIVE s(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM s WHERE i < \(count - 1)),
                     x(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM x WHERE a < \(apps))
                INSERT INTO \(appTable)(ts, app_id\(n ? ", n" : ""), \(app.joined(separator: ", ")))
                SELECT \(first) + i * \(step), a\(n ? ", 12" : ""), \(appValues) FROM s, x;
                """
        }
        return """
            WITH RECURSIVE x(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM x WHERE a < 40)
            INSERT INTO app(id, key_kind, key_id, name, bundle_path)
            SELECT a, 'app', 'com.example.app' || a, 'App ' || a, '/Applications/App' || a || '.app' FROM x;
            \(level("system_raw", "app_raw", n: false, step: Int64(rawStep) * 1_000, count: Int64(3_600 / rawStep), apps: 28))
            \(level("system_1m", "app_1m", n: true, step: 60_000, count: 1_440, apps: 32))
            \(level("system_15m", "app_15m", n: true, step: 900_000, count: 672, apps: 36))
            """
    }
}
