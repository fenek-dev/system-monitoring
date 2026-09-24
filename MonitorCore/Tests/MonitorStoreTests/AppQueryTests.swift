import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

/// One hour at 5 s: A cpu 50 (net 1000 B/s), B cpu 20 in every other sample, C 5, D 1, other 10.
@Suite struct AppQueryTests {
    private let a = T.app("com.a", "A"), b = T.app("com.b", "B"), c = T.app("com.c", "C"), d = T.app("com.d", "D")
    private let hour = DateInterval(start: T.t0, duration: 3_600)

    private func seeded(start: Date = T.t0, clock: TestClock = TestClock()) async throws -> HistoryStore {
        let store = try HistoryStore(location: .inMemory, config: T.config(clock))
        try await T.fill(store, from: start, duration: 3_600) { t, i in
            var apps: [(AppIdentity, [AppMetric: Double])] = [
                (a, [.cpu: 50, .netRx: 1_000, .memory: 1e9]), (c, [.cpu: 5]), (d, [.cpu: 1]), (T.other, [.cpu: 10]),
            ]
            if i % 2 == 0 { apps.append((b, [.cpu: 20])) }
            return T.record(at: t, system: [.cpuUsage: Double(i % 4) * 10, .netRx: 1_000], apps: apps)
        }
        return store
    }

    @Test func appSeriesAveragesWithAbsentAsZeroAndGaps() async throws {
        let store = try await seeded()
        try await store.execute("DELETE FROM system_raw WHERE ts >= \((T.t0 + 600).unixMs) AND ts < \((T.t0 + 900).unixMs)")
        let result = try await store.appSeries(a.key, [.cpu, .netRx], range: .hour, end: T.t0 + 3_600)
        let cpu = try #require(result[.cpu])
        #expect(cpu.count == 240)
        #expect(cpu.filter { $0.value == nil }.count == 20)                 // 5 min without system rows
        #expect(cpu.compactMap(\.value).allSatisfy { $0 == 50 })
        #expect(result[.netRx]?.compactMap(\.value).allSatisfy { $0 == 1_000 } == true)

        let bCPU = try #require(try await store.appSeries(b.key, [.cpu], range: .hour, end: T.t0 + 3_600, bucket: .seconds(60))[.cpu])
        #expect(bCPU.compactMap(\.value).allSatisfy { abs($0 - 10) < 1e-9 })

        let unknown = try #require(try await store.appSeries(AppKey(kind: .app, id: "nope"), [.cpu], range: .hour,
                                                             end: T.t0 + 3_600)[.cpu])
        #expect(unknown.compactMap(\.value).allSatisfy { $0 == 0 })
        #expect(unknown.compactMap(\.value).count == 220)
    }

    @Test func appSeriesMissingMetricIsNilNotZero() async throws {
        let store = try await seeded()
        let gpu = try #require(try await store.appSeries(a.key, [.gpu], range: .hour, end: T.t0 + 3_600)[.gpu])
        #expect(gpu.allSatisfy { $0.value == nil })
    }

    @Test func appSharesFoldTailIntoOtherAndSumToOne() async throws {
        let store = try await seeded()
        // Bucket [t0+90, t0+105): samples 18, 19, 20 → B present twice → 40/3.
        let shares = try await store.appShares(at: T.t0 + 100, metric: .cpu, range: .hour, limit: 2)
        #expect(shares.map(\.id) == [a.key, b.key, .other])
        #expect(shares[0].value == 50)
        #expect(abs(shares[1].value - 40.0 / 3) < 1e-9)
        #expect(abs(shares[2].value - 16) < 1e-9)                            // C 5 + D 1 + other 10
        #expect(abs(shares.map(\.fraction).reduce(0, +) - 1) < 1e-9)
        #expect(shares[0].identity.displayName == "A")

        let all = try await store.appShares(at: T.t0 + 100, metric: .cpu, range: .hour, limit: 10)
        #expect(all.count == 5)
        #expect(all.last?.id == .other)
        #expect(abs(all.map(\.fraction).reduce(0, +) - 1) < 1e-9)
    }

    @Test func appSharesWithoutDataIsEmpty() async throws {
        let store = try await seeded()
        #expect(try await store.appShares(at: T.t0 - 86_400, metric: .cpu, range: .hour, limit: 5).isEmpty)
        #expect(try await store.appShares(at: T.t0 + 100, metric: .gpu, range: .hour, limit: 5).isEmpty)
    }

    @Test func topAppsRanksAverageWithPeakAndTotal() async throws {
        let store = try await seeded()
        let top = try await store.topApps(.cpu, in: hour, limit: 3)
        #expect(top.map(\.identity.key) == [a.key, b.key, c.key])            // .other is not ranked
        #expect(top[0].average == 50)
        #expect(top[0].peak == 50)
        #expect(abs((top[0].total ?? 0) - 50 * 3_600) < 1e-6)                // value × seconds
        #expect(abs(top[1].average - 10) < 1e-9)
        #expect(top[1].peak == 20)
        let memory = try await store.topApps(.memory, in: hour, limit: 1)
        #expect(memory.first?.total == nil)
        #expect(memory.first?.average == 1e9)
    }

    @Test func longTopAppsIntervalsReadMinuteRollupsPlusRawTail() async throws {
        let store = try await seeded()
        let twoHours = DateInterval(start: T.t0 - 3_600, duration: 7_200)
        // Nothing rolled up yet: the raw tail answers everything.
        let fromTail = try await store.topApps(.cpu, in: twoHours, limit: 2)
        #expect(fromTail.map(\.identity.key) == [a.key, b.key])
        #expect(fromTail[1].peak == 20)
        // First 30 min rolled up: those rows come from app_1m (B's peak is now a 1 m average), the rest from raw.
        try await store.maintain(now: T.t0 + 1_800)
        try await store.execute("DELETE FROM app_raw WHERE ts < \((T.t0 + 1_800).unixMs)")   // prove 1 m is read
        let mixed = try await store.topApps(.cpu, in: twoHours, limit: 2)
        #expect(mixed.map(\.identity.key) == [a.key, b.key])
        #expect(mixed[0].average == 50)
        #expect(abs(mixed[1].average - 10) < 1e-9)
        #expect(abs((mixed[0].total ?? 0) - 50 * 3_600) < 1e-6)
        #expect(mixed[1].peak == 20)                                         // raw-tail rows still hold 20
        // A 1 h interval stays on raw.
        #expect(try await store.topApps(.cpu, in: DateInterval(start: T.t0 + 1_800, duration: 1_800), limit: 2)[1].peak == 20)
    }

    @Test func systemTotalAndPeak() async throws {
        let store = try await seeded()
        #expect(try await store.total(.netRx, in: hour) == 1_000 * 3_600)
        #expect(try await store.peak(.cpuUsage, in: hour) == 30)
        #expect(try await store.total(.gpuUsage, in: hour) == nil)
        #expect(try await store.peak(.cpuUsage, in: DateInterval(start: T.t0 - 7_200, duration: 3_600)) == nil)
    }

    @Test func olderIntervalsReadRollups() async throws {
        let clock = TestClock()
        let start = T.t0 - 3 * 86_400
        let store = try await seeded(start: start, clock: clock)
        try await store.maintain(now: T.t0)
        #expect(try await store.intValue("SELECT COUNT(*) FROM app_raw") == 0)
        let interval = DateInterval(start: start, duration: 3_600)
        let top = try await store.topApps(.cpu, in: interval, limit: 1)
        #expect(top.first?.average == 50)
        #expect(abs((top.first?.total ?? 0) - 50 * 3_600) < 1e-6)
        #expect(try await store.total(.netRx, in: interval) == 1_000 * 3_600)
        #expect(try await store.peak(.cpuUsage, in: interval) == 15)          // max of 1 min averages
    }
}
