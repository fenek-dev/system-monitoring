import Foundation
import MonitorModel
import os
@testable import MonitorStore

/// Injectable, thread-safe clock for `StoreConfig.now`.
final class TestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ start: Date = T.t0) { state = OSAllocatedUnfairLock(initialState: start) }

    var now: Date { state.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
    func set(_ date: Date) { state.withLock { $0 = date } }
}

enum T {
    /// 2026-09-21 14:00:00 UTC, aligned to 2 h (so every display bucket starts on it).
    static let t0 = Date(timeIntervalSince1970: 1_789_999_200)

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telltale-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func tempDB() -> URL { tempDir().appendingPathComponent("history.sqlite") }

    static func config(_ clock: TestClock, flushMaxRecords: Int = 120) -> StoreConfig {
        var c = StoreConfig()
        c.flushMaxRecords = flushMaxRecords
        c.now = { clock.now }
        return c
    }

    static func app(_ id: String, _ name: String? = nil) -> AppIdentity {
        AppIdentity(key: AppKey(kind: .app, id: id), displayName: name ?? id, bundlePath: "/Applications/\(id).app")
    }

    static let other = AppIdentity(key: .other, displayName: "Other")

    static func record(
        at time: Date,
        interval: Duration = .seconds(5),
        system: [HistoryMetric: Double] = [:],
        apps: [(AppIdentity, [AppMetric: Double])] = []
    ) -> HistoryRecord {
        var s = SystemMetrics()
        for (k, v) in system { s[k] = v }
        return HistoryRecord(time: time, interval: interval, system: s, apps: apps.map { identity, values in
            var m = AppMetrics()
            for (k, v) in values { m[k] = v }
            return AppRecord(identity: identity, metrics: m)
        })
    }

    /// Appends records every `step` seconds over [start, start + duration), then flushes.
    static func fill(
        _ store: HistoryStore,
        from start: Date,
        duration: TimeInterval,
        step: TimeInterval = 5,
        _ make: (Date, Int) -> HistoryRecord
    ) async throws {
        var i = 0
        var t = start
        while t < start.addingTimeInterval(duration) {
            await store.append(RecordBatch(record: make(t, i)))
            i += 1
            t = t.addingTimeInterval(step)
        }
        try await store.flush()
    }
}
