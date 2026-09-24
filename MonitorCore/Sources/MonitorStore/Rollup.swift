import GRDB
import MonitorModel

/// raw → 1 m → 15 m. Only completed buckets (end ≤ now); the newest rolled bucket is recomputed each pass
/// (`INSERT OR REPLACE … GROUP BY`), so passes are idempotent.
/// System rows: time-weighted averages (by `interval_ms`), `n` = sample count, `interval_ms` = covered time.
/// App rows: Σ value × span ÷ (bucket's covered time − span where the metric was NULL) — absent = 0;
/// `n` = samples the app was present in.
/// Fold (ruling R-I2, size): an app whose bucket average passes none of `RollupThresholds` is folded into the
/// bucket's `other` row (per-metric sum of the folded averages), so rollups keep only the apps that mattered.
enum Rollup {
    /// `rawCutoff`/`minuteCutoff`: retention cutoffs of the source levels (rows below may be partially deleted).
    static func run(_ db: Database, columns: Columns, thresholds: RollupThresholds?, nowMs: Int64,
                    rawCutoff: Int64, minuteCutoff: Int64) throws {
        try roll(db, from: .raw, to: .minute, columns: columns, thresholds: thresholds, nowMs: nowMs,
                 sourceCutoff: rawCutoff)
        try roll(db, from: .minute, to: .quarter, columns: columns, thresholds: thresholds, nowMs: nowMs,
                 sourceCutoff: minuteCutoff)
    }

    private static func roll(_ db: Database, from source: Level, to target: Level, columns: Columns,
                             thresholds: RollupThresholds?, nowMs: Int64, sourceCutoff: Int64) throws {
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

        // A recomputed bucket may hold a folded `other` row (and no rows for the apps folded into it): start
        // from scratch, or folding again would count those apps twice.
        try db.execute(sql: "DELETE FROM \(target.appTable) WHERE ts >= ? AND ts < ?", arguments: [start, upto])
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

        if let thresholds, let qualifies = thresholds.sql(appColumns: columns.app) {
            try fold(db, table: target.appTable, columns: appCols, qualifies: qualifies, from: start, to: upto)
        }
    }

    /// Every bucket in [from, to) is rewritten above (all its apps, `other` from the source), so folding again
    /// on a recomputed bucket starts from unfolded rows: idempotent.
    private static func fold(_ db: Database, table: String, columns: [String], qualifies: String,
                             from: Int64, to: Int64) throws {
        var otherID = try Int64.fetchOne(db, sql: "SELECT id FROM app WHERE key_kind = ? AND key_id = ?",
                                         arguments: [AppKey.other.kind.rawValue, AppKey.other.id])
        let pending = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM \(table) WHERE ts >= ? AND ts < ? AND app_id IS NOT ? AND NOT (\(qualifies)))
            """, arguments: [from, to, otherID]) ?? false
        guard pending else { return }
        if otherID == nil {
            otherID = try Int64.fetchOne(db, sql: """
                INSERT INTO app(key_kind, key_id, name) VALUES (?, ?, 'Other') RETURNING id
                """, arguments: [AppKey.other.kind.rawValue, AppKey.other.id])
        }
        guard let otherID else { return }
        let list = columns.map { ", \($0)" }.joined()
        let sums = columns.map { ", SUM(\($0))" }.joined()
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(table)(ts, app_id, n\(list))
            SELECT ts, ?, MAX(n)\(sums) FROM \(table)
            WHERE ts >= ? AND ts < ? AND (app_id = ? OR NOT (\(qualifies)))
            GROUP BY ts
            HAVING SUM(app_id != ?) > 0
            """, arguments: [otherID, from, to, otherID, otherID])
        try db.execute(sql: "DELETE FROM \(table) WHERE ts >= ? AND ts < ? AND app_id != ? AND NOT (\(qualifies))",
                       arguments: [from, to, otherID])
    }
}

/// `RecordConfig`'s per-app thresholds (MonitorEngine; the runtime passes its values), applied to rollup bucket
/// averages: an app is kept individually when any is met.
public struct RollupThresholds: Sendable, Equatable {
    public var minCPUPercent: Double
    public var minNetBps: Double
    public var minDiskBps: Double
    public var minMemory: Double

    /// Defaults = `RecordConfig()`'s; any GPU > 0 also qualifies.
    public init(minCPUPercent: Double = 0.5, minNetBps: Double = 1_024, minDiskBps: Double = 102_400,
                minMemory: Double = Double(200 << 20)) {
        self.minCPUPercent = minCPUPercent
        self.minNetBps = minNetBps
        self.minDiskBps = minDiskBps
        self.minMemory = minMemory
    }

    /// SQL predicate over an app row's (NULL = 0) columns; nil when the table has none of the threshold columns.
    func sql(appColumns: [String]) -> String? {
        let have = Set(appColumns)
        func col(_ m: AppMetric) -> String? { have.contains(m.rawValue) ? "COALESCE(\(Schema.quoted(m.rawValue)), 0)" : nil }
        func sum(_ a: AppMetric, _ b: AppMetric) -> String? {
            let parts = [col(a), col(b)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " + ")
        }
        let terms = [
            col(.cpu).map { "\($0) >= \(minCPUPercent)" },
            col(.gpu).map { "\($0) > 0" },
            sum(.netRx, .netTx).map { "\($0) >= \(minNetBps)" },
            sum(.diskRead, .diskWrite).map { "\($0) >= \(minDiskBps)" },
            col(.memory).map { "\($0) >= \(minMemory)" },
        ].compactMap { $0 }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }
}
