import Foundation
import GRDB
import os

enum StoreDatabase {
    static let log = Logger(subsystem: "dev.telltale", category: "MonitorStore")
    /// SQLite busy timeout for every connection (seconds).
    static let busyTimeout: TimeInterval = 1.5

    /// Opens (creating if needed), applies pragmas, migrates and adds missing metric columns.
    /// A file written by a newer schema (`user_version` > ours) is moved aside and a fresh file started.
    static func open(_ location: HistoryStore.Location, columns: Columns) throws -> any DatabaseWriter {
        switch location {
        case .inMemory:
            let queue = try DatabaseQueue(configuration: configuration())
            try prepare(queue, columns: columns)
            return queue
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var pool = try DatabasePool(path: url.path, configuration: configuration())
            let found = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
            if found > Schema.version {
                try pool.close()
                let aside = try moveAside(url)
                log.error("history.sqlite has user_version \(found) > \(Schema.version); moved to \(aside.lastPathComponent, privacy: .public)")
                pool = try DatabasePool(path: url.path, configuration: configuration())
            }
            try prepare(pool, columns: columns)
            return pool
        }
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = "dev.telltale.history"
        // Another connection to the same file (a previous store still finishing a flush or maintenance pass,
        // a second app instance) must make us wait, not fail the open with SQLITE_BUSY. Ruling: 1.5 s, so the
        // final flush in `shutdown()` completes or fails well inside the runtime's 3 s termination budget.
        config.busyMode = .timeout(StoreDatabase.busyTimeout)
        config.prepareDatabase { db in
            // Writer connection only: DatabasePool gives its reader connections a copy of this configuration
            // with `readonly = true` (GRDB `DatabasePool.readerConfiguration`); the in-memory queue is the writer.
            // prepareDatabase runs before GRDB switches the pool to WAL. auto_vacuum only takes effect on an
            // empty file, so it is set only then (page_count 0): setting it on an existing file would take a
            // write lock for nothing.
            if !db.configuration.readonly, try Int.fetchOne(db, sql: "PRAGMA page_count") == 0 {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
            try db.execute(sql: "PRAGMA synchronous = NORMAL; PRAGMA cache_size = -2000")
        }
        return config
    }

    private static func prepare(_ writer: some DatabaseWriter, columns: Columns) throws {
        try Schema.migrator(columns).migrate(writer)
        try writer.write { db in try Schema.ensureColumns(db, columns) }
    }

    /// Renames the database (and its -wal/-shm siblings) to `<name>.newer-<unix time>[-wal|-shm]`.
    private static func moveAside(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        var target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).newer-\(stamp)")
        var suffix = 1
        while fm.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).newer-\(stamp)-\(suffix)")
            suffix += 1
        }
        try fm.moveItem(at: url, to: target)
        for ext in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + ext)
            if fm.fileExists(atPath: side.path) {
                try? fm.moveItem(at: side, to: URL(fileURLWithPath: target.path + ext))
            }
        }
        return target
    }
}
