import Foundation
import GRDB
import os

/// TEST-ONLY API: internal hooks for `@testable` tests (the test target does not import GRDB). Not for app code.
extension HistoryStore {
    func columns(in table: String) async throws -> Set<String> {
        try await writer.read { db in Set(try db.columns(in: table).map(\.name)) }
    }

    func intValue(_ sql: String) async throws -> Int? {
        try await writer.read { db in try Int.fetchOne(db, sql: sql) }
    }

    func doubleValue(_ sql: String) async throws -> Double? {
        try await writer.read { db in try Double.fetchOne(db, sql: sql) }
    }

    func stringValue(_ sql: String) async throws -> String? {
        try await writer.read { db in try String.fetchOne(db, sql: sql) }
    }

    /// Per-connection pragmas must be read on the writer connection.
    func writerInt(_ sql: String) async throws -> Int? {
        try await writer.writeWithoutTransaction { db in try Int.fetchOne(db, sql: sql) }
    }

    /// Retention alone (no flush, no rollup).
    func runRetention(now: Date) async throws {
        let cutoffs = Retention.cutoffs(nowMs: now.unixMs, config: config)
        try await writer.write { db in try Retention.run(db, cutoffs) }
    }

    /// Holds the write lock (a real write in an open transaction) for `seconds`; calls `locked` once held.
    func holdWriteLock(seconds: TimeInterval, locked: @escaping @Sendable () -> Void) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO app(key_kind, key_id, name) VALUES ('other', 'lock-holder', '')")
            locked()
            Thread.sleep(forTimeInterval: seconds)
            try db.execute(sql: "DELETE FROM app WHERE key_id = 'lock-holder'")
        }
    }

    /// Holds the write lock (a real write in an open transaction) until `release` is flipped to `true`; calls
    /// `locked` once held. Unlike `holdWriteLock(seconds:)`, the hold isn't tied to wall-clock duration, so it can't
    /// be released early (or late) relative to the caller's own busy-retry timing under system load — the caller
    /// releases only once it has observed the busy behavior it's testing for.
    func holdWriteLockUntilReleased(
        locked: @escaping @Sendable () -> Void,
        release: OSAllocatedUnfairLock<Bool>
    ) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO app(key_kind, key_id, name) VALUES ('other', 'lock-holder', '')")
            locked()
            while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
            try db.execute(sql: "DELETE FROM app WHERE key_id = 'lock-holder'")
        }
    }

    func execute(_ sql: String) async throws {
        try await writer.write { db in try db.execute(sql: sql) }
    }
}
