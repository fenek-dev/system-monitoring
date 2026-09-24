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

    /// Free pages above which a pass returns them to the OS (4 MB at 4 KB pages); below, SQLite reuses them.
    static let vacuumThresholdPages = 1_024

    /// `PRAGMA incremental_vacuum` when the freelist is large (auto_vacuum = INCREMENTAL). Outside a transaction.
    static func vacuumIfNeeded(_ db: Database, threshold: Int = vacuumThresholdPages) throws {
        let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        guard free > threshold else { return }
        try db.execute(sql: "PRAGMA incremental_vacuum")
    }
}
