import GRDB

/// raw → 1 m → 15 m. Only completed buckets (end ≤ now); the newest rolled bucket is recomputed each pass
/// (`INSERT OR REPLACE … GROUP BY`), so passes are idempotent.
/// System rows: sample-weighted averages, `n` = samples, `interval_ms` = covered time.
/// App rows: sum over present samples ÷ the bucket's system `n` (absent = 0); `n` = that system `n`.
enum Rollup {
    static func run(_ db: Database, columns: Columns, nowMs: Int64) throws {
        try roll(db, from: .raw, to: .minute, columns: columns, nowMs: nowMs)
        try roll(db, from: .minute, to: .quarter, columns: columns, nowMs: nowMs)
    }

    private static func roll(_ db: Database, from source: Level, to target: Level, columns: Columns, nowMs: Int64) throws {
        let width = target.resolutionMs
        let upto = Buckets.floorDiv(nowMs, width) * width
        let start = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM \(target.systemTable)") ?? Int64.min
        guard start < upto else { return }
        let n = source.nColumn

        let sysCols = columns.system.map(Schema.quoted)
        let sysAverages = sysCols.map { ", SUM(\($0) * n) / SUM(CASE WHEN \($0) IS NOT NULL THEN n END)" }.joined()
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(target.systemTable)(ts, n, interval_ms\(sysCols.map { ", \($0)" }.joined()))
            SELECT (ts / \(width)) * \(width) AS b, SUM(n), SUM(interval_ms)\(sysAverages)
            FROM (SELECT ts, \(n) AS n, interval_ms\(sysCols.map { ", \($0)" }.joined())
                  FROM \(source.systemTable) WHERE ts >= ? AND ts < ?)
            GROUP BY b
            """, arguments: [start, upto])

        let appCols = columns.app.map(Schema.quoted)
        let appAverages = appCols.map { ", SUM(a.\($0) * a.n) * 1.0 / MAX(s.n)" }.joined()
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(target.appTable)(ts, app_id, n\(appCols.map { ", \($0)" }.joined()))
            SELECT a.b, a.app_id, MAX(s.n)\(appAverages)
            FROM (SELECT (ts / \(width)) * \(width) AS b, app_id, \(n) AS n\(appCols.map { ", \($0)" }.joined())
                  FROM \(source.appTable) WHERE ts >= ? AND ts < ?) AS a
            JOIN \(target.systemTable) AS s ON s.ts = a.b
            GROUP BY a.b, a.app_id
            """, arguments: [start, upto])
    }
}
