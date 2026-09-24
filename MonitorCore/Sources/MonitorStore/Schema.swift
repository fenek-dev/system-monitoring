import GRDB
import MonitorModel

/// Storage resolution. Raw rows are samples; rollup rows are bucket averages with `n` samples.
enum Level: Int, CaseIterable, Sendable {
    case raw, minute, quarter

    var systemTable: String {
        switch self {
        case .raw: "system_raw"
        case .minute: "system_1m"
        case .quarter: "system_15m"
        }
    }

    var appTable: String {
        switch self {
        case .raw: "app_raw"
        case .minute: "app_1m"
        case .quarter: "app_15m"
        }
    }

    /// Bucket width of a rollup row (raw: finest sampling interval).
    var resolutionMs: Int64 {
        switch self {
        case .raw: 1_000
        case .minute: 60_000
        case .quarter: 900_000
        }
    }

    /// `n` expression: raw rows are one sample each.
    var nColumn: String { self == .raw ? "1" : "n" }
}

/// Metric column sets. Default = today's `HistoryMetric`/`AppMetric` cases; tests inject extras.
struct Columns: Sendable {
    var system: [String]
    var app: [String]

    static let current = Columns(system: HistoryMetric.allCases.map(\.rawValue), app: AppMetric.allCases.map(\.rawValue))
}

enum Schema {
    /// `PRAGMA user_version` written by migration v1. A newer value means a newer app wrote the file.
    static let version = 1

    static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func migrator(_ columns: Columns) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            let sys = columns.system.map { "\(quoted($0)) REAL" }.joined(separator: ", ")
            let app = columns.app.map { "\(quoted($0)) REAL" }.joined(separator: ", ")
            try db.execute(sql: """
                CREATE TABLE app(id INTEGER PRIMARY KEY, key_kind TEXT NOT NULL, key_id TEXT NOT NULL,
                                 name TEXT, bundle_path TEXT, UNIQUE(key_kind, key_id));
                CREATE TABLE system_raw(ts INTEGER PRIMARY KEY, interval_ms INTEGER, \(sys));
                CREATE TABLE system_1m(ts INTEGER PRIMARY KEY, n INTEGER, interval_ms INTEGER, \(sys));
                CREATE TABLE system_15m(ts INTEGER PRIMARY KEY, n INTEGER, interval_ms INTEGER, \(sys));
                CREATE TABLE app_raw(ts INTEGER NOT NULL, app_id INTEGER NOT NULL, \(app),
                                     PRIMARY KEY(ts, app_id)) WITHOUT ROWID;
                CREATE TABLE app_1m(ts INTEGER NOT NULL, app_id INTEGER NOT NULL, n INTEGER, \(app),
                                    PRIMARY KEY(ts, app_id)) WITHOUT ROWID;
                CREATE TABLE app_15m(ts INTEGER NOT NULL, app_id INTEGER NOT NULL, n INTEGER, \(app),
                                     PRIMARY KEY(ts, app_id)) WITHOUT ROWID;
                CREATE INDEX app_raw_app ON app_raw(app_id, ts);
                CREATE INDEX app_1m_app ON app_1m(app_id, ts);
                CREATE INDEX app_15m_app ON app_15m(app_id, ts);
                CREATE TABLE event(id TEXT PRIMARY KEY, kind TEXT NOT NULL, start INTEGER NOT NULL, "end" INTEGER,
                                   level INTEGER NOT NULL, app_id INTEGER, metric TEXT, peak REAL, label TEXT NOT NULL);
                CREATE INDEX event_start ON event(start);
                PRAGMA user_version = \(version);
                """)
        }
        return migrator
    }

    /// Additive metrics: `ALTER TABLE … ADD COLUMN <name> REAL` for every metric column a table lacks.
    static func ensureColumns(_ db: Database, _ columns: Columns) throws {
        for level in Level.allCases {
            try addMissing(db, table: level.systemTable, wanted: columns.system)
            try addMissing(db, table: level.appTable, wanted: columns.app)
        }
    }

    static func hasMissingColumns(_ db: Database, _ columns: Columns) throws -> Bool {
        for level in Level.allCases {
            let system = Set(try db.columns(in: level.systemTable).map(\.name))
            let app = Set(try db.columns(in: level.appTable).map(\.name))
            if !system.isSuperset(of: columns.system) || !app.isSuperset(of: columns.app) { return true }
        }
        return false
    }

    private static func addMissing(_ db: Database, table: String, wanted: [String]) throws {
        let existing = Set(try db.columns(in: table).map(\.name))
        for name in wanted where !existing.contains(name) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(quoted(name)) REAL")
        }
    }
}
