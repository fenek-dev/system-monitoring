import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct EventQueryTests {
    private func store() throws -> HistoryStore {
        try HistoryStore(location: .inMemory, config: T.config(TestClock()))
    }

    @Test func eventsRoundTripEveryField() async throws {
        let store = try store()
        let withApp = HistoryEvent(kind: .runawayApp, start: T.t0, end: T.t0 + 300, level: .critical,
                                   app: T.app("com.x", "X"), metric: .cpu, peak: 187.5, label: "X runaway")
        let bare = HistoryEvent(kind: .samplingPaused, start: T.t0 + 60, end: nil, level: .calm, label: "Paused")
        await store.append(RecordBatch(events: [bare, withApp]))
        try await store.flush()
        let got = try await store.events(in: DateInterval(start: T.t0, duration: 3_600))
        #expect(got == [withApp, bare])
    }

    @Test func eventsOverlappingTheIntervalOnly() async throws {
        let store = try store()
        let events = [
            HistoryEvent(kind: .systemSleep, start: T.t0 - 600, end: T.t0 - 300, label: "before"),
            HistoryEvent(kind: .systemSleep, start: T.t0 - 600, end: T.t0 + 60, label: "straddles-start"),
            HistoryEvent(kind: .thermalPressure, start: T.t0 - 7_200, end: nil, label: "open"),
            HistoryEvent(kind: .memoryPressure, start: T.t0 + 1_800, end: T.t0 + 1_900, label: "inside"),
            HistoryEvent(kind: .swapGrowth, start: T.t0 + 3_600, end: nil, label: "after"),
        ]
        await store.append(RecordBatch(events: events))
        try await store.flush()
        let got = try await store.events(in: DateInterval(start: T.t0, duration: 3_600))
        #expect(got.map(\.label) == ["open", "straddles-start", "inside"])
    }

    @Test func unknownStoredKindIsSkipped() async throws {
        let store = try store()
        await store.append(RecordBatch(events: [HistoryEvent(kind: .appEpisode, start: T.t0, label: "ok")]))
        try await store.flush()
        try await store.execute("""
            INSERT INTO event(id, kind, start, level, label) VALUES ('x', 'fromTheFuture', \(T.t0.unixMs), 9, 'future')
            """)
        let got = try await store.events(in: DateInterval(start: T.t0 - 1, duration: 60))
        #expect(got.map(\.label) == ["ok"])
    }

    @Test func coverageSpansOldestRollupToNewestSample() async throws {
        let store = try store()
        #expect(try await store.coverage() == nil)
        try await T.fill(store, from: T.t0, duration: 600) { t, _ in T.record(at: t, system: [.cpuUsage: 1]) }
        #expect(try await store.coverage() == DateInterval(start: T.t0, end: T.t0 + 595))

        try await store.execute("INSERT INTO system_15m(ts, n, interval_ms, cpuUsage) VALUES (\((T.t0 - 86_400 * 10).unixMs), 1, 5000, 1)")
        #expect(try await store.coverage()?.start == T.t0 - 86_400 * 10)
        #expect(try await store.coverage()?.end == T.t0 + 595)
    }

    @Test func coverageWithRollupsOnly() async throws {
        let store = try store()
        let ts = (T.t0 - 86_400 * 3).unixMs
        try await store.execute("INSERT INTO system_1m(ts, n, interval_ms, cpuUsage) VALUES (\(ts), 12, 60000, 1)")
        #expect(try await store.coverage() == DateInterval(start: Date(unixMs: ts), end: Date(unixMs: ts + 60_000)))
    }
}
