import Foundation
import GRDB

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

    func execute(_ sql: String) async throws {
        try await writer.write { db in try db.execute(sql: sql) }
    }
}
