import Foundation
import GRDB
import MonitorModel

/// Half-open time window [from, to) in unix ms.
struct Window: Sendable {
    var from: Int64, to: Int64
}

/// Epoch-aligned display buckets covering a window.
struct Buckets: Sendable {
    var width: Int64
    var firstKey: Int64, lastKey: Int64

    /// Buckets for `duration` ending at `end`: keys floor(start / w) … ceil(end / w) − 1.
    init(end: Date, duration: Duration, width: Int64) {
        let w = max(width, 1)
        let endMs = end.unixMs
        let startMs = endMs - duration.milliseconds
        self.width = w
        self.firstKey = Self.floorDiv(startMs, w)
        self.lastKey = Self.floorDiv(endMs + w - 1, w) - 1
    }

    /// Rows are read from the first bucket's start up to `end` (never past it).
    func window(end: Date) -> Window { Window(from: firstKey * width, to: end.unixMs) }

    var keys: ClosedRange<Int64> { firstKey...max(firstKey, lastKey) }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

enum Queries {
    // MARK: Sources

    /// Subquery yielding `(ts, n, interval_ms, <cols>)` for [from, to) at `level`. For rollup levels, raw rows
    /// newer than the last rolled-up bucket fill the tail (rollups lag by up to one maintenance pass).
    static func systemSource(_ db: Database, level: Level, cols: [String], window: Window) throws
        -> (sql: String, arguments: StatementArguments) {
        let list = cols.map(Schema.quoted).map { ", \($0)" }.joined()
        let raw = "SELECT ts, 1 AS n, interval_ms\(list) FROM system_raw WHERE ts >= ? AND ts < ?"
        guard level != .raw else { return (raw, [window.from, window.to]) }
        let tail = try rawTailStart(db, level: level, window: window)
        let rolled = "SELECT ts, n, interval_ms\(list) FROM \(level.systemTable) WHERE ts >= ? AND ts < ?"
        return ("\(rolled) UNION ALL \(raw)", [window.from, min(tail, window.to), tail, window.to])
    }

    /// Subquery yielding `(ts, app_id, n, <cols>)`; `appID` restricts to one app.
    static func appSource(_ db: Database, level: Level, cols: [String], window: Window, appID: Int64? = nil) throws
        -> (sql: String, arguments: StatementArguments) {
        let list = cols.map(Schema.quoted).map { ", \($0)" }.joined()
        let appFilter = appID == nil ? "" : " AND app_id = ?"
        func args(_ from: Int64, _ to: Int64) -> StatementArguments {
            var a: StatementArguments = [from, to]
            if let appID { a += [appID] }
            return a
        }
        let raw = "SELECT ts, app_id, 1 AS n\(list) FROM app_raw WHERE ts >= ? AND ts < ?\(appFilter)"
        guard level != .raw else { return (raw, args(window.from, window.to)) }
        let tail = try rawTailStart(db, level: level, window: window)
        let rolled = "SELECT ts, app_id, n\(list) FROM \(level.appTable) WHERE ts >= ? AND ts < ?\(appFilter)"
        return ("\(rolled) UNION ALL \(raw)", args(window.from, min(tail, window.to)) + args(tail, window.to))
    }

    /// End of the newest rolled-up bucket (raw rows from here on are not yet in `level`'s table).
    private static func rawTailStart(_ db: Database, level: Level, window: Window) throws -> Int64 {
        guard let newest = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM \(level.systemTable)") else {
            return window.from
        }
        return max(window.from, newest + level.resolutionMs)
    }

    // MARK: System series

    /// Bucket key → per-column weighted average (nil = no non-null samples).
    static func systemBuckets(_ db: Database, cols: [String], level: Level, window: Window, width: Int64) throws
        -> [Int64: [Double?]] {
        let source = try systemSource(db, level: level, cols: cols, window: window)
        let aggregates = cols.map(Schema.quoted).map {
            ", SUM(\($0) * n) / SUM(CASE WHEN \($0) IS NOT NULL THEN n END)"
        }.joined()
        let sql = "SELECT ts / \(width) AS k\(aggregates) FROM (\(source.sql)) GROUP BY k"
        var result: [Int64: [Double?]] = [:]
        let rows = try Row.fetchCursor(db, sql: sql, arguments: source.arguments)
        while let row = try rows.next() {
            let key: Int64 = row[0]
            result[key] = (0..<cols.count).map { finite(row[$0 + 1]) }
        }
        return result
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// One point per bucket key; keys without a row are gaps.
    static func points(_ buckets: Buckets, _ rows: [Int64: [Double?]], column: Int) -> [SeriesPoint] {
        buckets.keys.map { k in
            SeriesPoint(time: Date(unixMs: k * buckets.width), value: rows[k]?[column] ?? nil)
        }
    }
}

extension Level {
    /// Range → table: live/hour/day → raw; week → 1 m; month → 15 m.
    static func forRange(_ range: HistoryRange) -> Level {
        switch range {
        case .live, .hour, .day: .raw
        case .week: .minute
        case .month: .quarter
        }
    }
}

extension HistoryRange {
    var span: Duration { duration ?? .seconds(60) }
}
