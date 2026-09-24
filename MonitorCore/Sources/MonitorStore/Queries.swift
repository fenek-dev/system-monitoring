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

    /// Subquery yielding `(ts, app_id, n, span_ms, <cols>)`; `span_ms` = the system row's covered time.
    /// `appID` restricts to one app.
    static func appSource(_ db: Database, level: Level, cols: [String], window: Window, appID: Int64? = nil) throws
        -> (sql: String, arguments: StatementArguments) {
        let list = cols.map(Schema.quoted).map { ", a.\($0)" }.joined()
        let appFilter = appID == nil ? "" : " AND a.app_id = ?"
        func args(_ from: Int64, _ to: Int64) -> StatementArguments {
            var a: StatementArguments = [from, to]
            if let appID { a += [appID] }
            return a
        }
        func branch(_ l: Level) -> String {
            """
            SELECT a.ts AS ts, a.app_id AS app_id, \(l == .raw ? "1" : "a.n") AS n, s.interval_ms AS span_ms\(list)
            FROM \(l.appTable) AS a JOIN \(l.systemTable) AS s ON s.ts = a.ts
            WHERE a.ts >= ? AND a.ts < ?\(appFilter)
            """
        }
        guard level != .raw else { return (branch(.raw), args(window.from, window.to)) }
        let tail = try rawTailStart(db, level: level, window: window)
        return ("\(branch(level)) UNION ALL \(branch(.raw))", args(window.from, min(tail, window.to)) + args(tail, window.to))
    }

    static func appID(_ db: Database, _ key: AppKey) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM app WHERE key_kind = ? AND key_id = ?",
                           arguments: [key.kind.rawValue, key.id])
    }

    static func identity(_ row: Row, kind: String, id: String, name: String, bundle: String) -> AppIdentity {
        let key = AppKey(kind: AppKey.Kind(rawValue: row[kind]) ?? .other, id: row[id])
        return AppIdentity(key: key, displayName: row[name] ?? "", bundlePath: row[bundle])
    }

    // MARK: Events, coverage

    /// Events overlapping [from, to) (open events extend to now), by start. Rows with an unknown kind
    /// (written by a newer version) are skipped.
    static func events(_ db: Database, window: Window) throws -> [HistoryEvent] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT e.id, e.kind, e.start, e."end", e.level, e.metric, e.peak, e.label,
                   app.key_kind, app.key_id, app.name, app.bundle_path
            FROM event AS e LEFT JOIN app ON app.id = e.app_id
            WHERE e.start < ? AND (e."end" IS NULL OR e."end" >= ?)
            ORDER BY e.start, e.id
            """, arguments: [window.to, window.from])
        var result: [HistoryEvent] = []
        while let row = try rows.next() {
            guard let id = UUID(uuidString: row[0]), let kind = HistoryEvent.Kind(rawValue: row[1]) else { continue }
            let hasApp = (row[9] as String?) != nil
            result.append(HistoryEvent(
                id: id, kind: kind, start: Date(unixMs: row[2]), end: (row[3] as Int64?).map(Date.init(unixMs:)),
                level: AlertLevel(rawValue: row[4]) ?? .calm,
                app: hasApp ? identity(row, kind: "key_kind", id: "key_id", name: "name", bundle: "bundle_path") : nil,
                metric: (row[5] as String?).flatMap(AppMetric.init(rawValue:)),
                peak: row[6], label: row[7] ?? ""))
        }
        return result
    }

    /// Oldest stored bucket/sample → newest raw sample (or the end of the newest rollup bucket when raw is empty).
    static func coverage(_ db: Database) throws -> DateInterval? {
        var oldest: Int64?
        var newestRolled: Int64?
        for level in Level.allCases {
            let row = try Row.fetchOne(db, sql: "SELECT MIN(ts), MAX(ts) FROM \(level.systemTable)")
            if let min: Int64 = row?[0] { oldest = Swift.min(oldest ?? min, min) }
            if level != .raw, let max: Int64 = row?[1] {
                newestRolled = Swift.max(newestRolled ?? Int64.min, max + level.resolutionMs)
            }
        }
        guard let start = oldest else { return nil }
        let rawNewest = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM system_raw")
        guard let end = rawNewest ?? newestRolled else { return nil }
        return DateInterval(start: Date(unixMs: start), end: Date(unixMs: Swift.max(start, end)))
    }

    // MARK: App series / aggregates

    /// Bucket key → per-column app average over the bucket's samples (absent = 0; nil = unavailable),
    /// only for buckets that have system rows.
    static func appBuckets(_ db: Database, key: AppKey, cols: [String], level: Level, window: Window, width: Int64) throws
        -> [Int64: [Double?]] {
        let sys = try systemSource(db, level: level, cols: [], window: window)
        var samples: [Int64: Double] = [:]
        let sysRows = try Row.fetchCursor(db, sql: "SELECT ts / \(width) AS k, SUM(n) FROM (\(sys.sql)) GROUP BY k",
                                          arguments: sys.arguments)
        while let row = try sysRows.next() { samples[row[0]] = row[1] }

        var sums: [Int64: [Double?]] = [:]
        if let id = try appID(db, key) {
            let app = try appSource(db, level: level, cols: cols, window: window, appID: id)
            let aggregates = cols.map(Schema.quoted).map { ", SUM(\($0) * n)" }.joined()
            let rows = try Row.fetchCursor(db, sql: "SELECT ts / \(width) AS k\(aggregates) FROM (\(app.sql)) GROUP BY k",
                                           arguments: app.arguments)
            while let row = try rows.next() { sums[row[0]] = (0..<cols.count).map { row[$0 + 1] } }
        }

        var result: [Int64: [Double?]] = [:]
        for (k, n) in samples where n > 0 {
            guard let row = sums[k] else {
                result[k] = Array(repeating: 0, count: cols.count)
                continue
            }
            result[k] = row.map { $0.flatMap { finite($0 / n) } }
        }
        return result
    }

    /// Per-app average (absent = 0), peak and integral (value × seconds) of one metric over a window.
    struct AppTotals: Sendable {
        var identity: AppIdentity
        var average: Double, peak: Double, integral: Double
    }

    static func appTotals(_ db: Database, metric: String, level: Level, window: Window) throws -> [AppTotals] {
        let sys = try systemSource(db, level: level, cols: [], window: window)
        guard let samples = try Double.fetchOne(db, sql: "SELECT SUM(n) FROM (\(sys.sql))", arguments: sys.arguments),
              samples > 0 else { return [] }
        let col = Schema.quoted(metric)
        let app = try appSource(db, level: level, cols: [metric], window: window)
        let rows = try Row.fetchAll(db, sql: """
            SELECT app.key_kind, app.key_id, app.name, app.bundle_path,
                   SUM(x.\(col) * x.n), MAX(x.\(col)), SUM(x.\(col) * x.span_ms) / 1000.0
            FROM (\(app.sql)) AS x JOIN app ON app.id = x.app_id
            WHERE x.\(col) IS NOT NULL
            GROUP BY x.app_id
            """, arguments: app.arguments)
        return rows.compactMap { row in
            guard let sum = finite(row[4]) else { return nil }
            return AppTotals(identity: identity(row, kind: "key_kind", id: "key_id", name: "name", bundle: "bundle_path"),
                             average: sum / samples, peak: finite(row[5]) ?? 0, integral: finite(row[6]) ?? 0)
        }
    }

    /// System metric aggregate over a window: integral (value × seconds) and peak.
    static func systemAggregate(_ db: Database, metric: String, level: Level, window: Window)
        throws -> (integral: Double?, peak: Double?) {
        let col = Schema.quoted(metric)
        let sys = try systemSource(db, level: level, cols: [metric], window: window)
        let row = try Row.fetchOne(db, sql: """
            SELECT SUM(\(col) * interval_ms) / 1000.0, MAX(\(col)) FROM (\(sys.sql)) WHERE \(col) IS NOT NULL
            """, arguments: sys.arguments)
        return (finite(row?[0]), finite(row?[1]))
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
