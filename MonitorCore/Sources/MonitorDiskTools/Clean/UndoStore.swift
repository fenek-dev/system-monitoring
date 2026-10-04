import Darwin
import Foundation
import MonitorModel
import Synchronization

/// Persisted Move-to-Trash records (`dataDirectory/storage-undo.json`, atomic writes) and the restore that moves
/// items back out of the Trash.
public final class UndoStore: Sendable {
    public static let maxAge: TimeInterval = 7 * 86400

    private let file: String
    private let permittedRoot: String
    private let lock = Mutex(0)
    private let beforeRename: (@Sendable () -> Void)?

    /// `permittedRoot`: restores recreate missing parents below it and refuse to leave it.
    public convenience init(file: String, permittedRoot: String) {
        self.init(file: file, permittedRoot: permittedRoot, beforeRename: nil)
    }

    /// `beforeRename`: test seam, runs just before each rename attempt's identity check.
    init(file: String, permittedRoot: String, beforeRename: (@Sendable () -> Void)?) {
        self.file = file
        self.permittedRoot = permittedRoot
        self.beforeRename = beforeRename
    }

    public func records() throws -> [UndoRecord] {
        try lock.withLock { _ in try load() }
    }

    public func append(_ record: UndoRecord) throws {
        try lock.withLock { _ in
            var all = try load()
            all.append(record)
            try save(all)
        }
    }

    /// Drops entries whose Trash item is gone, and records older than 7 days.
    public func prune(now: Date) throws {
        try lock.withLock { _ in
            var kept: [UndoRecord] = []
            for var record in try load() where now.timeIntervalSince(record.date) <= Self.maxAge {
                record.entries = record.entries.filter { Self.trashItemExists($0) }
                if !record.entries.isEmpty { kept.append(record) }
            }
            try save(kept)
        }
    }

    /// Moves each entry back. Per entry: the Trash folder must be the recorded one and the Trash item the recorded
    /// inode (never a same-named substitute); the original parent is reopened below the permitted root, missing
    /// components recreated without following symlinks; the move never overwrites (`name (restored)`, …).
    /// Failures are outcomes in the final report; restored entries leave the stored record.
    public func restore(_ record: UndoRecord) -> AsyncStream<CleanEvent> {
        AsyncStream { continuation in
            let work: @Sendable () -> Void = { [self] in
                var report = CleanReport()
                var restoredIDs = Set<Int32>()
                for entry in record.entries {
                    switch restoreEntry(entry) {
                    case let .done(finalPath):
                        restoredIDs.insert(entry.itemID)
                        report.outcomes.append(CleanItemOutcome(itemID: entry.itemID))
                        continuation.yield(.restored(itemID: entry.itemID, finalPath: finalPath))
                        DiskTools.log.notice("undo: restored \(finalPath, privacy: .public)")
                    case let .refused(reason):
                        report.outcomes.append(CleanItemOutcome(itemID: entry.itemID, skip: reason))
                        DiskTools.log.error("undo: \(entry.originalPath, privacy: .public) not restored: \(String(describing: reason), privacy: .public)")
                    }
                }
                forget(record.id, restored: restoredIDs)
                continuation.yield(.finished(report))
                continuation.finish()
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    // MARK: - Restore

    private enum Restored {
        case done(String)
        case refused(SkipReason)
    }

    private static func duplicateRoot(_ root: TrustedRoot) throws(SafePathError) -> FileDescriptor {
        let raw = try root.withDescriptor { (fd: Int32) throws(SafePathError) -> Int32 in
            try CleanFS.duplicate(fd).take()
        }
        return FileDescriptor(adopting: raw)
    }

    private func restoreEntry(_ entry: UndoEntry) -> Restored {
        do {
            let trashRoot = try TrustedRoot(path: entry.trashParentPath)
            guard trashRoot.identity == entry.trashParentIdentity else {
                return .refused(.failed("Trash folder changed"))
            }
            let trashRel = try trashRoot.relativePath(of: entry.trashPath)
            guard trashRel.components.count == 1 else { return .refused(.failed("Trash path not in Trash folder")) }
            let trashLeaf = trashRel.leaf

            return try trashRoot.withDescriptor { (trashFd: Int32) throws(SafePathError) -> Restored in
                // Rename keeps the inode, so the item we trashed still has the recorded identity; anything else under
                // that name is not ours to move.
                guard CleanFS.identity(of: trashLeaf, in: trashFd) == entry.identity else {
                    return .refused(.failed("Trash item was replaced"))
                }
                let parentPath = (entry.originalPath as NSString).deletingLastPathComponent
                let name = (entry.originalPath as NSString).lastPathComponent
                // Destination first (it can take a while and creates directories), source check last: the identity
                // is re-verified right before every rename attempt so nothing that replaced the item in between
                // is moved.
                let destination = try openOrCreateParent(parentPath)
                var candidate = name
                var attempt = 0
                while true {
                    beforeRename?()
                    guard CleanFS.identity(of: trashLeaf, in: trashFd) == entry.identity else {
                        return .refused(.failed("Trash item was replaced"))
                    }
                    do throws(SafePathError) {
                        try CleanFS.exclusiveRename(fromDir: trashFd, trashLeaf, toDir: destination.rawValue, candidate)
                        return .done(parentPath + "/" + candidate)
                    } catch {
                        guard error.errno == EEXIST, attempt < 10_000 else { throw error }
                        attempt += 1
                        candidate = attempt == 1 ? "\(name) (restored)" : "\(name) (restored \(attempt))"
                    }
                }
            }
        } catch {
            return .refused(CleanFS.skipReason(for: error))
        }
    }

    /// The original parent below the permitted root; missing components are created with `mkdirat` and entered with
    /// `O_NOFOLLOW`, so a symlink standing where a directory should be is refused (`ELOOP`), not followed.
    private func openOrCreateParent(_ parentPath: String) throws(SafePathError) -> FileDescriptor {
        let root = try TrustedRoot(path: permittedRoot)
        let rel: RelativePath
        do {
            rel = try root.relativePath(of: parentPath)
        } catch SafePathError.outsideRoot where parentPath == permittedRoot || parentPath == root.canonicalPath {
            return try Self.duplicateRoot(root)
        }
        var current = try Self.duplicateRoot(root)
        for component in rel.components {
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            do {
                current = try FileDescriptor.open(at: current.rawValue, component, flags: flags)
            } catch where error.errno == ENOENT {
                guard mkdirat(current.rawValue, component, 0o755) == 0 || errno == EEXIST else {
                    throw .posix(op: "mkdirat \(component)", errno: errno)
                }
                current = try FileDescriptor.open(at: current.rawValue, component, flags: flags)
            }
        }
        return current
    }

    private static func trashItemExists(_ entry: UndoEntry) -> Bool {
        do {
            let root = try TrustedRoot(path: entry.trashParentPath)
            let rel = try root.relativePath(of: entry.trashPath)
            guard rel.components.count == 1 else { return false }
            return try root.withDescriptor { (fd: Int32) throws(SafePathError) in
                CleanFS.identity(of: rel.leaf, in: fd) == entry.identity
            }
        } catch {
            // An unmounted volume can't be told apart from a deleted item: keep the entry until it ages out.
            return error.errno != ENOENT
        }
    }

    // MARK: - Persistence

    private func forget(_ id: UUID, restored: Set<Int32>) {
        guard !restored.isEmpty else { return }
        lock.withLock { _ in
            do {
                var all = try load()
                guard let index = all.firstIndex(where: { $0.id == id }) else { return }
                all[index].entries.removeAll { restored.contains($0.itemID) }
                if all[index].entries.isEmpty { all.remove(at: index) }
                try save(all)
            } catch {
                DiskTools.log.error("undo: record not updated after restore: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func load() throws -> [UndoRecord] {
        guard FileManager.default.fileExists(atPath: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([UndoRecord].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    }

    private func save(_ records: [UndoRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let directory = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try encoder.encode(records).write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
