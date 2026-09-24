import Foundation
import GRDB
import MonitorModel

extension Date {
    /// Unix milliseconds (storage time format).
    var unixMs: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded()) }
    init(unixMs: Int64) { self.init(timeIntervalSince1970: Double(unixMs) / 1_000) }
}

extension Duration {
    var milliseconds: Int64 {
        let c = components
        return c.seconds * 1_000 + c.attoseconds / 1_000_000_000_000_000
    }

    var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Writes one flush (records + events) inside the caller's transaction.
enum RecordWriter {
    typealias AppIDCache = [AppKey: (id: Int64, identity: AppIdentity)]

    static func write(_ records: [HistoryRecord], _ events: [HistoryEvent], _ db: Database) throws {
        var appIDs: AppIDCache = [:]
        let systemMetrics = HistoryMetric.allCases
        let appMetrics = AppMetric.allCases

        if !records.isEmpty {
            let sysCols = systemMetrics.map { Schema.quoted($0.rawValue) }.joined(separator: ", ")
            let sysMarks = Array(repeating: "?", count: systemMetrics.count + 2).joined(separator: ", ")
            let insertSystem = try db.cachedStatement(sql:
                "INSERT OR REPLACE INTO system_raw(ts, interval_ms, \(sysCols)) VALUES (\(sysMarks))")
            let appCols = appMetrics.map { Schema.quoted($0.rawValue) }.joined(separator: ", ")
            let appMarks = Array(repeating: "?", count: appMetrics.count + 2).joined(separator: ", ")
            let insertApp = try db.cachedStatement(sql:
                "INSERT OR REPLACE INTO app_raw(ts, app_id, \(appCols)) VALUES (\(appMarks))")

            var values: [(any DatabaseValueConvertible)?] = []
            values.reserveCapacity(systemMetrics.count + 2)
            for record in records {
                let ts = record.time.unixMs
                values.removeAll(keepingCapacity: true)
                values.append(ts)
                values.append(nominalIntervalMs(record.interval))
                for m in systemMetrics { values.append(record.system[m]) }
                try insertSystem.execute(arguments: StatementArguments(values))

                for app in record.apps {
                    let id = try appID(app.identity, db, &appIDs)
                    values.removeAll(keepingCapacity: true)
                    values.append(ts)
                    values.append(id)
                    for m in appMetrics { values.append(app.metrics[m]) }
                    try insertApp.execute(arguments: StatementArguments(values))
                }
            }
        }

        if !events.isEmpty {
            let insertEvent = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO event(id, kind, start, "end", level, app_id, metric, peak, label)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for e in events {
                let app = try e.app.map { try appID($0, db, &appIDs) }
                try insertEvent.execute(arguments: [
                    e.id.uuidString, e.kind.rawValue, e.start.unixMs, e.end?.unixMs, e.level.rawValue,
                    app, e.metric?.rawValue, e.peak.flatMap { $0.isFinite ? $0 : nil }, e.label,
                ])
            }
        }
    }

    /// Longest cadence a sample may claim (background is 5 s).
    static let maxNominalIntervalMs: Int64 = 60_000
    /// Used when a record carries no interval.
    static let defaultIntervalMs: Int64 = 5_000

    /// `interval_ms` = the sample's NOMINAL cadence (1 s / 5 s), not the time since the previous sample, so the
    /// first record after a pause or sleep weighs one interval and never covers the gap. Clamped to
    /// 1 ms…60 s as a guard; ≤ 0 → 5 s.
    static func nominalIntervalMs(_ interval: Duration) -> Int64 {
        let ms = interval.milliseconds
        guard ms > 0 else { return defaultIntervalMs }
        return min(ms, maxNominalIntervalMs)
    }

    /// Upserts the app row once per flush (name/bundle path follow the latest record).
    private static func appID(_ identity: AppIdentity, _ db: Database, _ cache: inout AppIDCache) throws -> Int64 {
        if let hit = cache[identity.key], hit.identity == identity { return hit.id }
        let statement = try db.cachedStatement(sql: """
            INSERT INTO app(key_kind, key_id, name, bundle_path) VALUES (?, ?, ?, ?)
            ON CONFLICT(key_kind, key_id) DO UPDATE SET name = excluded.name, bundle_path = excluded.bundle_path
            RETURNING id
            """)
        let id = try Int64.fetchOne(statement, arguments: [
            identity.key.kind.rawValue, identity.key.id, identity.displayName, identity.bundlePath,
        ]) ?? 0
        cache[identity.key] = (id, identity)
        return id
    }
}
