import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

/// Advisory (ARCHITECTURE §7): run with `TELLTALE_PERF=1 scripts/test.sh StorePerfTests`; prints `PERF` lines.
/// Default: 30 days of 5 s samples (518 400 system rows) with 25 apps above threshold + `other` per sample, written
/// through `append` (flush every 30 s of samples), maintenance every 5 simulated minutes.
/// `TELLTALE_PERF_CADENCE=1` samples every 1 s (UI open) and flushes every 30 records; `TELLTALE_PERF_DAYS=n`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELLTALE_PERF"] == "1"))
struct StorePerfTests {
    @Test func thirtyDaysAtFiveSeconds() async throws {
        let env = ProcessInfo.processInfo.environment
        let days = Int(env["TELLTALE_PERF_DAYS"] ?? "30") ?? 30
        let cadence = max(Int(env["TELLTALE_PERF_CADENCE"] ?? "5") ?? 5, 1)
        let perFlush = max(30 / cadence, 1)
        let perMaintenance = max(300 / cadence, 1)
        let clock = TestClock()
        let url = T.tempDB()
        let store = try HistoryStore(location: .file(url), config: T.config(clock, flushMaxRecords: perFlush))
        let pool = (0..<60).map { T.app("com.perf.app\($0)", "App \($0)") }
        let start = T.t0
        let samples = days * 86_400 / cadence
        let step = Double(cadence)
        var rng = SplitMix(seed: 7)

        let writeStart = ContinuousClock.now
        var maintenance: [Double] = []
        for i in 0..<samples {
            let t = start + Double(i) * step
            clock.set(t)
            await store.append(RecordBatch(record: Self.record(at: t, index: i, cadence: cadence, pool: pool, rng: &rng)))
            if i % perMaintenance == perMaintenance - 1 {                              // the store's 5 min timer, in simulated time
                maintenance.append(try await ContinuousClock().measure { try await store.maintain(now: t) }.timeInterval * 1_000)
            }
        }
        try await store.flush()
        let writeSeconds = (ContinuousClock.now - writeStart).timeInterval
        let end = start + Double(samples) * step

        // One explicit maintenance pass and flush timings in steady state.
        let maintainTime = try await ContinuousClock().measure { try await store.maintain(now: end) }
        for k in 0..<6 { await store.append(RecordBatch(record: Self.record(at: end + Double(k) * step, index: samples + k, cadence: cadence, pool: pool, rng: &rng))) }
        let flush6 = try await ContinuousClock().measure { try await store.flush() }
        for k in 6..<126 { await store.append(RecordBatch(record: Self.record(at: end + Double(k) * step, index: samples + k, cadence: cadence, pool: pool, rng: &rng))) }
        let flush120 = try await ContinuousClock().measure { try await store.flush() }

        _ = try await store.writerInt("PRAGMA wal_checkpoint(TRUNCATE)")
        let dbBytes = Self.fileSize(url) + Self.fileSize(URL(fileURLWithPath: url.path + "-wal"))
        var counts: [String] = []
        for table in ["system_raw", "system_1m", "system_15m", "app_raw", "app_1m", "app_15m", "app"] {
            counts.append("\(table)=\(try await store.intValue("SELECT COUNT(*) FROM \(table)") ?? -1)")
        }

        let metrics: [HistoryMetric] = [.cpuUsage, .memUsed, .netRx, .netTx, .gpuUsage, .packageWatts]
        let queryEnd = end + 630
        func median(_ body: () async throws -> Void) async throws -> Double {
            var times: [Double] = []
            for _ in 0..<5 { times.append(try await ContinuousClock().measure { try await body() }.timeInterval * 1_000) }
            return times.sorted()[2]
        }
        let day = try await median { _ = try await store.series(metrics, range: .day, end: queryEnd) }
        let week = try await median { _ = try await store.series(metrics, range: .week, end: queryEnd) }
        let month = try await median { _ = try await store.series(metrics, range: .month, end: queryEnd) }
        let appWeek = try await median { _ = try await store.appSeries(pool[0].key, [.cpu, .memory], range: .week, end: queryEnd) }
        let shares = try await median { _ = try await store.appShares(at: queryEnd - 86_400 * 10, metric: .cpu, range: .month, limit: 12) }
        let top = try await median { _ = try await store.topApps(.cpu, in: DateInterval(start: queryEnd - 86_400, end: queryEnd), limit: 10) }
        let topHour = try await median { _ = try await store.topApps(.cpu, in: DateInterval(start: queryEnd - 3_600, end: queryEnd), limit: 10) }

        maintenance.sort()
        print(String(format: "PERF cadence=%ds days=%d samples=%d write=%.1fs maintain(final)=%.1fms maintain(p50/p99/max)=%.1f/%.1f/%.1fms flush6=%.2fms flush120=%.1fms",
                     cadence, days, samples, writeSeconds, maintainTime.timeInterval * 1_000,
                     maintenance[maintenance.count / 2], maintenance[maintenance.count * 99 / 100], maintenance.last ?? 0,
                     flush6.timeInterval * 1_000, flush120.timeInterval * 1_000))
        print(String(format: "PERF db=%.1fMB %@", Double(dbBytes) / 1_048_576, counts.joined(separator: " ")))
        print(String(format: "PERF series(6 metrics) day=%.1fms week=%.1fms month=%.1fms appSeries(week)=%.1fms appShares(month)=%.1fms topApps(24h)=%.1fms topApps(1h)=%.1fms",
                     day, week, month, appWeek, shares, top, topHour))
        #expect(dbBytes > 0)
    }

    private static func record(at t: Date, index i: Int, cadence: Int, pool: [AppIdentity], rng: inout SplitMix) -> HistoryRecord {
        var system = SystemMetrics()
        for m in HistoryMetric.allCases { system[m] = rng.next() * 100 }
        var apps: [AppRecord] = []
        apps.reserveCapacity(26)
        let rotation = (i * cadence / 600) % 8                       // background set changes every 10 min
        for j in 0..<25 {
            let identity = j < 20 ? pool[j] : pool[20 + (rotation * 5 + (j - 20)) % 40]
            var m = AppMetrics()
            m[.cpu] = rng.next() * 50
            m[.memory] = 1e8 + rng.next() * 1e9
            m[.netRx] = rng.next() * 1e5
            m[.netTx] = rng.next() * 1e4
            m[.diskRead] = rng.next() * 1e6
            m[.diskWrite] = rng.next() * 1e6
            m[.energy] = rng.next() * 2
            if j < 5 { m[.gpu] = rng.next() * 20 }
            apps.append(AppRecord(identity: identity, metrics: m))
        }
        var other = AppMetrics()
        other[.cpu] = rng.next() * 10
        other[.memory] = rng.next() * 1e9
        apps.append(AppRecord(identity: T.other, metrics: other))
        return HistoryRecord(time: t, interval: .seconds(cadence), system: system, apps: apps)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
