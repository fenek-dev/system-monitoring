import Foundation
import GRDB
import os

enum ClipboardDatabase {
    static let log = Logger(subsystem: "dev.telltale", category: "ClipboardStore")
    static let databaseName = "clipboard.sqlite"

    /// Opens (creating if needed) and migrates. A corrupt or non-SQLite file is moved aside to
    /// `clipboard.corrupt-<yyyyMMdd-HHmmss>.sqlite` and a fresh one is started.
    static func open(directory: URL, now: Date) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(databaseName)
        do {
            return try openFile(url)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT {
            let aside = try moveAside(url, to: corruptName(now))
            log.error("clipboard.sqlite unreadable (\(error.localizedDescription, privacy: .public)); moved to \(aside.lastPathComponent, privacy: .public)")
            return try openFile(url)
        }
    }

    static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: configuration())
        try migrator().migrate(queue)
        return queue
    }

    private static func openFile(_ url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path, configuration: configuration())
        try migrator().migrate(queue)
        // A damaged data page passes the migration and would only fail later, in the store's first read, outside
        // the move-aside above.
        let check = try queue.read { try String.fetchOne($0, sql: "PRAGMA quick_check(1)") }
        guard check == "ok" else { throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: check) }
        return queue
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = "dev.telltale.clipboard"
        config.busyMode = .timeout(1.5)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        return config
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE clip(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    hash TEXT NOT NULL UNIQUE,
                    text TEXT NOT NULL DEFAULT '',
                    text_length INTEGER NOT NULL DEFAULT 0,
                    files TEXT NOT NULL DEFAULT '[]',
                    image_file TEXT,
                    thumb_file TEXT,
                    image_width INTEGER NOT NULL DEFAULT 0,
                    image_height INTEGER NOT NULL DEFAULT 0,
                    byte_size INTEGER NOT NULL DEFAULT 0,
                    thumb_bytes INTEGER NOT NULL DEFAULT 0,
                    source_bundle TEXT,
                    source_name TEXT,
                    created_at REAL NOT NULL,
                    last_used_at REAL NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX clip_last_used ON clip(last_used_at);
                """)
        }
        return migrator
    }

    static func corruptName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "clipboard.corrupt-\(formatter.string(from: date)).sqlite"
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
                try fm.moveItem(at: side, to: URL(fileURLWithPath: target.path + ext))
            }
        }
        return target
    }
}
