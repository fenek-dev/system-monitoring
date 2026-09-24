import GRDB

/// raw → 1 m → 15 m. Only completed buckets (end ≤ now); the newest rolled bucket is recomputed each pass
/// (`INSERT OR REPLACE … GROUP BY`), so passes are idempotent.
/// System rows: time-weighted averages (by `interval_ms`), `n` = sample count, `interval_ms` = covered time.
/// App rows: Σ value × span ÷ (bucket's covered time − span where the metric was NULL) — absent = 0;
/// `n` = samples the app was present in.
enum Rollup {
    /// `rawCutoff`/`minuteCutoff`: retention cutoffs of the source levels (rows below may be partially deleted).
    static func run(_ db: Database, columns: Columns, nowMs: Int64, rawCutoff: Int64, minuteCutoff: Int64) throws {
        try roll(db, from: .raw, to: .minute, columns: columns, nowMs: nowMs, sourceCutoff: rawCutoff)
        try roll(db, from: .minute, to: .quarter, columns: columns, nowMs: nowMs, sourceCutoff: minuteCutoff)
    }

    private static func roll(_ db: Database, from source: Level, to target: Level, columns: Columns,
                             nowMs: Int64, sourceCutoff: Int64) throws {
        let width = target.resolutionMs
        let upto = Buckets.floorDiv(nowMs, width) * width
        // Rows at or after `upto` can only come from a clock that moved backwards; drop them so the
        // watermark below can't stall rollups until the clock catches up. They are rebuilt from the source later.
        try db.execute(sql: "DELETE FROM \(target.systemTable) WHERE ts >= ?", arguments: [upto])
        try db.execute(sql: "DELETE FROM \(target.appTable) WHERE ts >= ?", arguments: [upto])

        var start = Int64.min
        if let newest = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM \(target.systemTable)") {
            // Recompute the newest bucket, unless retention may already have trimmed its source rows.
            start = newest < sourceCutoff ? newest + width : newest
        }
        guard start < upto else { return }
        let n = source.nColumn

        let sysCols = columns.system.map(Schema.quoted)
        let sysList = sysCols.map { ", \($0)" }.joined()
        let sysAverages = sysCols.map { ", \(Queries.systemAverage($0))" }.joined()
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(target.systemTable)(ts, n, interval_ms\(sysList))
            SELECT (ts / \(width)) * \(width) AS b, SUM(n), SUM(interval_ms)\(sysAverages)
            FROM (SELECT ts, \(n) AS n, interval_ms\(sysList) FROM \(source.systemTable) WHERE ts >= ? AND ts < ?)
            GROUP BY b
            """, arguments: [start, upto])

        let appCols = columns.app.map(Schema.quoted)
        let appList = appCols.map { ", \($0)" }.joined()
        let appSelect = appCols.map { ", a.\($0)" }.joined()
        let appAverages = appCols.map {
            ", SUM(x.\($0) * x.span_ms) * 1.0 / (MAX(t.interval_ms) - COALESCE(SUM(CASE WHEN x.\($0) IS NULL THEN x.span_ms END), 0))"
        }.joined()
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(target.appTable)(ts, app_id, n\(appList))
            SELECT x.b, x.app_id, SUM(x.n)\(appAverages)
            FROM (SELECT (a.ts / \(width)) * \(width) AS b, a.app_id, \(source == .raw ? "1" : "a.n") AS n,
                         s.interval_ms AS span_ms\(appSelect)
                  FROM \(source.appTable) AS a JOIN \(source.systemTable) AS s ON s.ts = a.ts
                  WHERE a.ts >= ? AND a.ts < ?) AS x
            JOIN \(target.systemTable) AS t ON t.ts = x.b
            GROUP BY x.b, x.app_id
            """, arguments: [start, upto])
    }
}
