import Foundation
import GRDB
import os

enum StoreDatabase {
    static let log = Logger(subsystem: "dev.telltale", category: "MonitorStore")
    /// SQLite busy timeout for every connection (seconds).
    static let busyTimeout: TimeInterval = 1.5

    /// Opens (creating if needed), applies pragmas, migrates, adds missing metric columns and closes events a
    /// previous process left open. A file written by a newer schema (`user_version` > ours) is moved aside to
    /// `history.sqlite.newer-<time>`, a corrupt or non-SQLite file to `history.corrupt-<date>.sqlite`, and a fresh
    /// file is started.
    static func open(_ location: HistoryStore.Location, columns: Columns) throws -> any DatabaseWriter {
        switch location {
        case .inMemory:
            let queue = try DatabaseQueue(configuration: configuration())
            try prepare(queue, columns: columns)
            return queue
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            do {
                return try openFile(url, columns: columns)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT {
                let aside = try moveAside(url, to: corruptName(url))
                log.error("history.sqlite unreadable (\(error.localizedDescription, privacy: .public)); moved to \(aside.lastPathComponent, privacy: .public)")
                return try openFile(url, columns: columns)
            }
        }
    }

    private static func openFile(_ url: URL, columns: Columns) throws -> DatabasePool {
        var pool = try DatabasePool(path: url.path, configuration: configuration())
        let found = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        if found > Schema.version {
            try pool.close()
            let aside = try moveAside(url, to: "\(url.lastPathComponent).newer-\(Int(Date().timeIntervalSince1970))")
            log.error("history.sqlite has user_version \(found) > \(Schema.version); moved to \(aside.lastPathComponent, privacy: .public)")
            pool = try DatabasePool(path: url.path, configuration: configuration())
        }
        try prepare(pool, columns: columns)
        return pool
    }

    /// `history.corrupt-20260924T153012Z.sqlite` for `history.sqlite`.
    static func corruptName(_ url: URL, at date: Date = Date()) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted).timeZone(separator: .omitted))
        let ext = url.pathExtension
        return "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp)" + (ext.isEmpty ? "" : ".\(ext)")
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
            // Truncate the WAL back to 8 MB after a checkpoint that follows a large transaction (R-M3).
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA journal_size_limit = 8388608") }
        }
        return config
    }

    /// Migrates, then (in a write transaction only when there is something to do, so an up-to-date file opens
    /// without taking the write lock) adds missing metric columns and closes orphaned events.
    private static func prepare(_ writer: some DatabaseWriter, columns: Columns) throws {
        try Schema.migrator(columns).migrate(writer)
        let needsWrite = try writer.read { db in
            let openEvents = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM event WHERE \"end\" IS NULL)")
            return try Schema.hasMissingColumns(db, columns) || openEvents == true
        }
        guard needsWrite else { return }
        try writer.write { db in
            try Schema.ensureColumns(db, columns)
            try closeOrphanedEvents(db)
        }
    }

    /// Events still open (`end` NULL) when the store opens were left by a process that crashed, was killed or lost
    /// power before writing their closing row; this process never continues an old episode id (R-I1 / E-I2).
    /// Each ends at the last sample recorded at or after its start, or at its start when none was.
    static func closeOrphanedEvents(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE event SET "end" = COALESCE((SELECT MAX(ts) FROM system_raw WHERE ts >= event.start), start)
            WHERE "end" IS NULL
            """)
        let closed = db.changesCount
        if closed > 0 { log.notice("closed \(closed) events left open by the previous run") }
    }

    /// Renames the database (and its -wal/-shm siblings) to `name` (`-1`, `-2`… appended when taken).
    private static func moveAside(_ url: URL, to name: String) throws -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent(name)
        var suffix = 1
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(name)-\(suffix)")
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
