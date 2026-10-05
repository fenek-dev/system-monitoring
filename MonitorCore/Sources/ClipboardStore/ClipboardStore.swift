import ClipboardCore
import Foundation
import GRDB

/// Clipboard history on disk: rows in SQLite, image and thumbnail files next to it.
/// Never reads or deletes the files a `files` item points to.
public actor ClipboardStore {
    public enum Location: Sendable {
        /// `<dir>/clipboard.sqlite`, `<dir>/images/`.
        case directory(URL)
        case inMemory(imagesDirectory: URL)
    }

    public struct Stats: Equatable, Sendable {
        public var itemCount: Int
        public var byteSize: Int64

        public init(itemCount: Int, byteSize: Int64) {
            self.itemCount = itemCount
            self.byteSize = byteSize
        }
    }

    enum RecordError: Error { case missingRow(Int64) }

    public nonisolated let imagesDirectory: URL
    private let policy: ClipboardPolicy
    private let db: DatabaseQueue

    private static let selectColumns = """
        id, kind, hash, substr(text, 1, ?) AS text, text_length, files, image_file, thumb_file, image_width,
        image_height, byte_size, source_bundle, source_name, created_at, last_used_at, pinned
        """

    public init(location: Location, policy: ClipboardPolicy = .default, now: Date) throws {
        switch location {
        case .directory(let directory):
            db = try ClipboardDatabase.open(directory: directory, now: now)
            imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        case .inMemory(let images):
            db = try ClipboardDatabase.openInMemory()
            imagesDirectory = images
        }
        self.policy = policy
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try Self.removeOrphanImages(db, in: imagesDirectory)
        try Self.prune(db, policy: policy, now: now, imagesDirectory: imagesDirectory)
    }

    /// Inserts, or on an existing hash refreshes `lastUsedAt` and the source app (keeping `createdAt`, `pinned` and
    /// the id). nil: image bytes that ImageIO cannot decode; nothing is written.
    @discardableResult
    public func record(_ capture: ClipCapture, at now: Date) throws -> ClipItem? {
        let hash = capture.hash
        let stamp = now.timeIntervalSince1970
        let policy = policy
        let known = try db.read { try Int64.fetchOne($0, sql: "SELECT id FROM clip WHERE hash = ?", arguments: [hash]) }

        let id: Int64
        if let known {
            try db.write {
                try $0.execute(
                    sql: "UPDATE clip SET last_used_at = ?, source_bundle = ?, source_name = ? WHERE id = ?",
                    arguments: [stamp, capture.source.bundleID, capture.source.name, known]
                )
            }
            id = known
        } else {
            guard let inserted = try insert(capture, hash: hash, stamp: stamp) else { return nil }
            id = inserted
        }
        let item = try item(id)
        try Self.prune(db, policy: policy, now: now, imagesDirectory: imagesDirectory)
        return item
    }

    /// Pinned first, then `lastUsedAt` descending.
    public func items() throws -> [ClipItem] {
        let limit = policy.previewCharacters
        return try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(Self.selectColumns) FROM clip ORDER BY pinned DESC, last_used_at DESC, id DESC",
                arguments: [limit]
            ).map(Self.makeItem)
        }
    }

    public func fullText(_ id: Int64) throws -> String? {
        try db.read {
            try String.fetchOne($0, sql: "SELECT text FROM clip WHERE id = ? AND kind = 'text'", arguments: [id])
        }
    }

    /// PNG bytes of an image item.
    public func imageData(_ id: Int64) throws -> Data? {
        let file = try db.read {
            try String.fetchOne($0, sql: "SELECT image_file FROM clip WHERE id = ?", arguments: [id])
        }
        guard let file else { return nil }
        return try Data(contentsOf: imagesDirectory.appendingPathComponent(file))
    }

    public func touch(_ id: Int64, at now: Date) throws {
        try db.write {
            try $0.execute(sql: "UPDATE clip SET last_used_at = ? WHERE id = ?", arguments: [now.timeIntervalSince1970, id])
        }
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try db.write { try $0.execute(sql: "UPDATE clip SET pinned = ? WHERE id = ?", arguments: [pinned, id]) }
    }

    public func delete(_ id: Int64) throws {
        let files = try db.write { try Self.deleteRows($0, ids: [id]) }
        Self.removeFiles(files, in: imagesDirectory)
    }

    public func clearUnpinned() throws {
        let files = try db.write { db in
            try Self.deleteRows(db, ids: try Int64.fetchAll(db, sql: "SELECT id FROM clip WHERE pinned = 0"))
        }
        Self.removeFiles(files, in: imagesDirectory)
    }

    /// `byteSize` = text bytes + image and thumbnail file bytes.
    public func stats() throws -> Stats {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(byte_size + thumb_bytes), 0) AS bytes FROM clip")
            return Stats(itemCount: row?["n"] ?? 0, byteSize: row?["bytes"] ?? 0)
        }
    }

    // MARK: - Insert

    private func insert(_ capture: ClipCapture, hash: String, stamp: Double) throws -> Int64? {
        var text = ""
        var textLength = 0
        var files: [String] = []
        var byteSize: Int64 = 0
        var thumbBytes: Int64 = 0
        var imageFile: String?
        var thumbFile: String?
        var width = 0
        var height = 0

        switch capture.content {
        case .text(let value):
            text = value
            textLength = value.count
            byteSize = Int64(value.utf8.count)
        case .files(let paths):
            files = paths
        case .image(let data):
            guard let encoded = ImageEncoding.encode(data, thumbnailPixels: policy.thumbnailPixels) else { return nil }
            imageFile = "\(hash).png"
            thumbFile = "\(hash).thumb.png"
            width = encoded.width
            height = encoded.height
            byteSize = Int64(encoded.png.count)
            thumbBytes = Int64(encoded.thumbnail.count)
            try encoded.png.write(to: imagesDirectory.appendingPathComponent("\(hash).png"))
            try encoded.thumbnail.write(to: imagesDirectory.appendingPathComponent("\(hash).thumb.png"))
        }

        let filesJSON = String(decoding: try JSONEncoder().encode(files), as: UTF8.self)
        do {
            return try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO clip(kind, hash, text, text_length, files, image_file, thumb_file, image_width,
                                         image_height, byte_size, thumb_bytes, source_bundle, source_name,
                                         created_at, last_used_at, pinned)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        capture.kind.rawValue, hash, text, textLength, filesJSON, imageFile, thumbFile, width, height,
                        byteSize, thumbBytes, capture.source.bundleID, capture.source.name, stamp, stamp,
                    ]
                )
                return db.lastInsertedRowID
            }
        } catch {
            Self.removeFiles([imageFile, thumbFile].compactMap { $0 }, in: imagesDirectory)
            throw error
        }
    }

    private func item(_ id: Int64) throws -> ClipItem {
        let limit = policy.previewCharacters
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT \(Self.selectColumns) FROM clip WHERE id = ?", arguments: [limit, id])
            guard let row else { throw RecordError.missingRow(id) }
            return try Self.makeItem(row)
        }
    }

    private static func makeItem(_ row: Row) throws -> ClipItem {
        let filesJSON: String = row["files"]
        let created: Double = row["created_at"]
        let used: Double = row["last_used_at"]
        return ClipItem(
            id: row["id"],
            kind: ClipKind(rawValue: row["kind"]) ?? .text,
            text: row["text"],
            textLength: row["text_length"],
            files: try JSONDecoder().decode([String].self, from: Data(filesJSON.utf8)),
            imageFile: row["image_file"],
            thumbFile: row["thumb_file"],
            imageWidth: row["image_width"],
            imageHeight: row["image_height"],
            byteSize: row["byte_size"],
            hash: row["hash"],
            sourceBundleID: row["source_bundle"],
            sourceName: row["source_name"],
            createdAt: Date(timeIntervalSince1970: created),
            lastUsedAt: Date(timeIntervalSince1970: used),
            pinned: row["pinned"]
        )
    }

    // MARK: - Retention

    /// Unpinned items past the newest `maxItems`, unpinned items older than `maxAge`, then the oldest unpinned
    /// images while image bytes exceed `maxTotalImageBytes`. Image files of removed rows are deleted.
    private static func prune(_ db: DatabaseQueue, policy: ClipboardPolicy, now: Date, imagesDirectory: URL) throws {
        let files = try db.write { db in
            var removed: [String] = []
            let excess = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM clip WHERE pinned = 0 ORDER BY last_used_at DESC, id DESC LIMIT -1 OFFSET ?",
                arguments: [policy.maxItems]
            )
            removed += try deleteRows(db, ids: excess)
            let expired = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM clip WHERE pinned = 0 AND last_used_at < ?",
                arguments: [now.timeIntervalSince1970 - policy.maxAge]
            )
            removed += try deleteRows(db, ids: expired)

            var total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_size), 0) FROM clip WHERE kind = 'image'") ?? 0
            if total > policy.maxTotalImageBytes {
                let candidates = try Row.fetchAll(
                    db,
                    sql: "SELECT id, byte_size FROM clip WHERE kind = 'image' AND pinned = 0 ORDER BY last_used_at ASC, id ASC"
                )
                var oversize: [Int64] = []
                for row in candidates where total > policy.maxTotalImageBytes {
                    oversize.append(row["id"])
                    total -= row["byte_size"] as Int64
                }
                removed += try deleteRows(db, ids: oversize)
            }
            return removed
        }
        removeFiles(files, in: imagesDirectory)
    }

    /// Deletes the rows and returns the image and thumbnail file names they referenced.
    private static func deleteRows(_ db: Database, ids: [Int64]) throws -> [String] {
        var files: [String] = []
        for id in ids {
            if let row = try Row.fetchOne(db, sql: "SELECT image_file, thumb_file FROM clip WHERE id = ?", arguments: [id]) {
                files += [row["image_file"] as String?, row["thumb_file"] as String?].compactMap { $0 }
            }
            try db.execute(sql: "DELETE FROM clip WHERE id = ?", arguments: [id])
        }
        return files
    }

    private static func removeOrphanImages(_ db: DatabaseQueue, in directory: URL) throws {
        let referenced = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT image_file, thumb_file FROM clip WHERE kind = 'image'")
                .flatMap { [$0["image_file"] as String?, $0["thumb_file"] as String?] }
                .compactMap { $0 }
        }
        let present = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        removeFiles(present.filter { $0.hasSuffix(".png") && !referenced.contains($0) }, in: directory)
    }

    /// A file that cannot be removed stays on disk (the next open removes it as an orphan); it must not fail the
    /// operation that already changed the database.
    private static func removeFiles(_ names: [String], in directory: URL) {
        for name in names {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                ClipboardDatabase.log.error("could not remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
