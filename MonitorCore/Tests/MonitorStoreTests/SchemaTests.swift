import Foundation
import MonitorModel
import os
import Testing
@testable import MonitorStore

@Suite struct SchemaTests {
    private let systemNames = HistoryMetric.allCases.map(\.rawValue)
    private let appNames = AppMetric.allCases.map(\.rawValue)

    @Test func freshStoreHasEveryTableAndMetricColumn() async throws {
        let store = try HistoryStore(location: .inMemory)
        for table in ["system_raw", "system_1m", "system_15m"] {
            let cols = try await store.columns(in: table)
            #expect(Set(systemNames).isSubset(of: cols), "\(table)")
            #expect(cols.contains("ts"))
            #expect(cols.contains("interval_ms"))
        }
        #expect(try await store.columns(in: "system_1m").contains("n"))
        for table in ["app_raw", "app_1m", "app_15m"] {
            let cols = try await store.columns(in: table)
            #expect(Set(appNames).isSubset(of: cols), "\(table)")
            #expect(cols.isSuperset(of: ["ts", "app_id"]))
        }
        #expect(try await store.columns(in: "app_15m").contains("n"))
        #expect(try await store.columns(in: "event")
            .isSuperset(of: ["id", "kind", "start", "end", "level", "app_id", "metric", "peak", "label"]))
        #expect(try await store.columns(in: "app").isSuperset(of: ["id", "key_kind", "key_id", "name", "bundle_path"]))
    }

    @Test func missingMetricColumnsAreAddedAtOpen() async throws {
        let url = T.tempDB()
        do { _ = try HistoryStore(location: .file(url)) }   // v1 with today's metrics

        let store = try HistoryStore(location: .file(url), config: StoreConfig(),
                                     systemColumns: systemNames + ["fakeMetric"],
                                     appColumns: appNames + ["fakeAppMetric"])
        for table in ["system_raw", "system_1m", "system_15m"] {
            #expect(try await store.columns(in: table).contains("fakeMetric"), "\(table)")
        }
        for table in ["app_raw", "app_1m", "app_15m"] {
            #expect(try await store.columns(in: table).contains("fakeAppMetric"), "\(table)")
        }
    }

    @Test func olderDatabaseWithFewerColumnsGainsThem() async throws {
        let url = T.tempDB()
        do {
            _ = try HistoryStore(location: .file(url), config: StoreConfig(),
                                 systemColumns: ["cpuUsage"], appColumns: ["cpu"])
        }
        let store = try HistoryStore(location: .file(url))
        #expect(Set(systemNames).isSubset(of: try await store.columns(in: "system_raw")))
        #expect(Set(appNames).isSubset(of: try await store.columns(in: "app_1m")))
    }

    @Test func reopenIsIdempotent() async throws {
        let url = T.tempDB()
        var counts: [Int] = []
        for _ in 0..<3 {
            let store = try HistoryStore(location: .file(url))
            counts.append(try await store.columns(in: "system_raw").count)
            #expect(try await store.intValue("PRAGMA user_version") == Schema.version)
        }
        #expect(Set(counts).count == 1)
    }

    /// Regression (flaky reopen tests): opening while another store holds the write lock on the same file
    /// used to fail with SQLITE_BUSY from `PRAGMA auto_vacuum` in prepareDatabase.
    @Test func openWaitsForAnotherConnectionsWriteLock() async throws {
        let url = T.tempDB()
        let first = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        let locked = OSAllocatedUnfairLock(initialState: false)
        let holder = Task { try await first.holdWriteLock(seconds: 0.3) { locked.withLock { $0 = true } } }
        while !locked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        let second = try HistoryStore(location: .file(url), config: T.config(TestClock()))
        #expect(try await second.intValue("PRAGMA user_version") == Schema.version)
        try await holder.value
    }

    @Test func filePragmas() async throws {
        let store = try HistoryStore(location: .file(T.tempDB()))
        #expect(try await store.stringValue("PRAGMA journal_mode") == "wal")
        #expect(try await store.writerInt("PRAGMA auto_vacuum") == 2)       // INCREMENTAL
        #expect(try await store.writerInt("PRAGMA synchronous") == 1)       // NORMAL
        #expect(try await store.writerInt("PRAGMA cache_size") == -2000)
    }
}
