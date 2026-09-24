import GRDB

/// Deletes rows past each level's retention (raw 24 h, 1 m 7 d, 15 m 30 d; events 30 d after they end),
/// then apps nothing references. Runs after `Rollup` in the same transaction.
enum Retention {
    struct Cutoffs: Sendable {
        var raw: Int64, minute: Int64, quarter: Int64, events: Int64
    }

    static func cutoffs(nowMs: Int64, config: StoreConfig) -> Cutoffs {
        Cutoffs(raw: nowMs - config.rawRetention.milliseconds,
                minute: nowMs - config.minuteRetention.milliseconds,
                quarter: nowMs - config.quarterRetention.milliseconds,
                events: nowMs - config.quarterRetention.milliseconds)
    }

    static func run(_ db: Database, _ cutoffs: Cutoffs) throws {
        for (level, cutoff) in [(Level.raw, cutoffs.raw), (.minute, cutoffs.minute), (.quarter, cutoffs.quarter)] {
            try db.execute(sql: "DELETE FROM \(level.systemTable) WHERE ts < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM \(level.appTable) WHERE ts < ?", arguments: [cutoff])
        }
        try db.execute(sql: "DELETE FROM event WHERE COALESCE(\"end\", start) < ?", arguments: [cutoffs.events])
        try db.execute(sql: """
            DELETE FROM app WHERE NOT EXISTS (SELECT 1 FROM app_raw WHERE app_id = app.id)
              AND NOT EXISTS (SELECT 1 FROM app_1m WHERE app_id = app.id)
              AND NOT EXISTS (SELECT 1 FROM app_15m WHERE app_id = app.id)
              AND NOT EXISTS (SELECT 1 FROM event WHERE app_id = app.id)
            """)
    }

    struct SizeGuardResult: Sendable, Equatable {
        /// Raw rows before this were deleted.
        var rawCutoff: Int64
        var bytesBefore: Int64, bytesAfter: Int64
    }

    /// Size guard (ruling R-I2): when the database (`page_count × page_size`) exceeds `capBytes`, deletes the
    /// oldest raw rows in steps until the used pages fit 90 % of the cap, never at or after `keepFrom` (raw of the
    /// last hour). Raw that old is already rolled up to 1 m by the pass before. nil when nothing was pruned.
    /// Inside a transaction; the caller returns the freed pages (`PRAGMA incremental_vacuum`).
    static func enforceSize(_ db: Database, capBytes: Int64, keepFrom: Int64) throws -> SizeGuardResult? {
        let pageSize = Int64(try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4_096)
        func pages(_ pragma: String) throws -> Int64 { Int64(try Int.fetchOne(db, sql: "PRAGMA \(pragma)") ?? 0) }
        let fileBytes = try pages("page_count") * pageSize
        guard fileBytes > capBytes else { return nil }
        func usedBytes() throws -> Int64 { (try pages("page_count") - pages("freelist_count")) * pageSize }
        guard var cutoff = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM system_raw"), cutoff < keepFrom else {
            return nil
        }
        let target = capBytes / 10 * 9
        var used = try usedBytes()
        var pruned = false
        while used > target, cutoff < keepFrom {
            cutoff = min(cutoff + max((keepFrom - cutoff) / 8, 60_000), keepFrom)
            try db.execute(sql: "DELETE FROM system_raw WHERE ts < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM app_raw WHERE ts < ?", arguments: [cutoff])
            used = try usedBytes()
            pruned = true
        }
        return pruned ? SizeGuardResult(rawCutoff: cutoff, bytesBefore: fileBytes, bytesAfter: used) : nil
    }

    /// Oldest raw row when raw was pruned early (a 1 m bucket inside raw retention lies wholly before it), else nil.
    /// Queries starting before it read 1 m rollups instead of a raw gap.
    static func rawFloor(_ db: Database, rawCutoff: Int64) throws -> Int64? {
        guard let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM system_raw") else { return nil }
        let pruned = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM system_1m WHERE ts >= ? AND ts <= ?)",
                                       arguments: [rawCutoff, oldest - Level.minute.resolutionMs]) ?? false
        return pruned ? oldest : nil
    }

    /// Free pages above which a pass returns them to the OS (4 MB at 4 KB pages); below, SQLite reuses them.
    static let vacuumThresholdPages = 1_024

    /// `PRAGMA incremental_vacuum` when the freelist is large (auto_vacuum = INCREMENTAL). Outside a transaction.
    static func vacuumIfNeeded(_ db: Database, threshold: Int = vacuumThresholdPages) throws {
        let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        guard free > threshold else { return }
        try db.execute(sql: "PRAGMA incremental_vacuum")
    }
}
