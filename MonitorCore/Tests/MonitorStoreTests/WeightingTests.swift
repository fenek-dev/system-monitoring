import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

/// Averages and totals weigh samples by their nominal `interval` (1 s UI open, 5 s closed), not by count.
@Suite struct WeightingTests {
    private let app = T.app("com.a", "A")

    /// 60 s at 1 s cadence (value 10) then 60 s at 5 s cadence (value 40).
    private func mixed() async throws -> HistoryStore {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 60, step: 1) { t, _ in
            T.record(at: t, interval: .seconds(1), system: [.cpuUsage: 10, .netRx: 100], apps: [(app, [.cpu: 10, .netRx: 100])])
        }
        try await T.fill(store, from: T.t0 + 60, duration: 60) { t, _ in
            T.record(at: t, system: [.cpuUsage: 40, .netRx: 100], apps: [(app, [.cpu: 40, .netRx: 100])])
        }
        return store
    }

    @Test func mixedCadenceAveragesAreTimeWeighted() async throws {
        let store = try await mixed()
        let sys = try #require(try await store.series([.cpuUsage], range: .hour, end: T.t0 + 3_600, bucket: .seconds(120))[.cpuUsage])
        #expect(sys.first?.value == 25)                                     // not (60·10 + 12·40) / 72 = 15
        let appPoints = try #require(try await store.appSeries(app.key, [.cpu], range: .hour, end: T.t0 + 3_600,
                                                               bucket: .seconds(120))[.cpu])
        #expect(appPoints.first?.value == 25)
        let top = try await store.topApps(.cpu, in: DateInterval(start: T.t0, duration: 120), limit: 1)
        #expect(top.first?.average == 25)
    }

    @Test func mixedCadenceTotalsOnRawAndRollups() async throws {
        let clock = TestClock()
        let store = try await mixed()
        let interval = DateInterval(start: T.t0, duration: 120)
        #expect(try await store.total(.netRx, in: interval) == 100 * 120)
        #expect(try await store.topApps(.netRx, in: interval, limit: 1).first?.total == 100 * 120)

        // Same data after rollups, read from the 1 m level (raw expired).
        let rolled = try HistoryStore(location: .inMemory, config: T.config(clock))
        try await T.fill(rolled, from: T.t0 - 3 * 86_400, duration: 60, step: 1) { t, _ in
            T.record(at: t, interval: .seconds(1), system: [.netRx: 100, .cpuUsage: 10], apps: [(app, [.netRx: 100])])
        }
        try await T.fill(rolled, from: T.t0 - 3 * 86_400 + 60, duration: 60) { t, _ in
            T.record(at: t, system: [.netRx: 100, .cpuUsage: 40], apps: [(app, [.netRx: 100])])
        }
        try await rolled.maintain(now: T.t0)
        #expect(try await rolled.intValue("SELECT COUNT(*) FROM system_raw") == 0)
        let old = DateInterval(start: T.t0 - 3 * 86_400, duration: 120)
        #expect(try await rolled.total(.netRx, in: old) == 100 * 120)
        #expect(try await rolled.topApps(.netRx, in: old, limit: 1).first?.total == 100 * 120)
        let week = try #require(try await rolled.series([.cpuUsage], range: .week, end: T.t0, bucket: .seconds(120))[.cpuUsage])
        #expect(week.compactMap(\.value) == [25])
    }

    @Test func firstRecordAfterPauseDoesNotFillTheGap() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 600) { t, _ in T.record(at: t, system: [.netRx: 1]) }
        // Paused 10 min; the engine stamps the first sample after resume with its nominal 5 s cadence.
        try await T.fill(store, from: T.t0 + 1_200, duration: 600) { t, _ in T.record(at: t, system: [.netRx: 1]) }
        let hour = DateInterval(start: T.t0, duration: 1_800)
        #expect(try await store.total(.netRx, in: hour) == 1_200)            // 20 covered minutes, not 30
        let points = try #require(try await store.series([.netRx], range: .hour, end: T.t0 + 1_800, bucket: .seconds(60))[.netRx])
        #expect(points.filter { $0.time >= T.t0 + 600 && $0.time < T.t0 + 1_200 }.allSatisfy { $0.value == nil })
    }
}
