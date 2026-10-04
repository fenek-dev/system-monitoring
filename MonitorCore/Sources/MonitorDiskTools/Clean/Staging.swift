import Darwin
import Foundation
import MonitorModel

/// What sat at an item's original location, written before the item is moved so a crash can put it back.
struct PendingRecord: Codable, Equatable, Sendable {
    var parentPath: String
    var parentIdentity: FileIdentity
    var name: String
    var identity: FileIdentity
}

/// An entry that finished the journal and waits in `commit/` for deletion.
struct CommittedEntry: Sendable, Equatable {
    var name: String
    var identity: FileIdentity
}

enum DetachResult: Sendable, Equatable {
    case committed(CommittedEntry)
    /// `leftover`: the item stays in `staging/pending` (reported, never deleted).
    case skipped(SkipReason, leftover: Bool)
}

/// The open `staging/pending` and `staging/commit` directories of a clean run.
///
/// Remove mode is a two-step journal so a crash never loses data and a mismatch never deletes the wrong file:
/// 1. sidecar `pending/<uuid>.json` (original parent, its identity, the leaf name, the item's identity);
/// 2. rename item → `pending/<uuid>`, then compare the identity of what actually moved with the expected one;
///    mismatch → rename back, never delete;
/// 3. rename `pending/<uuid>` → `commit/<uuid>`, delete the sidecar.
/// Only `commit/` is ever deleted. Everything is a (dir fd, leaf) operation.
final class StagingJournal: Sendable {
    let pending: FileDescriptor
    let commit: FileDescriptor
    let commitPath: String
    let stagingDev: Int32
    private let hooks: CleanTestHooks

    init(pending: consuming FileDescriptor, commit: consuming FileDescriptor, commitPath: String,
         hooks: CleanTestHooks) throws(SafePathError) {
        let actualDev = try commit.identity().dev
        self.stagingDev = hooks.stagingDeviceOverride ?? actualDev
        self.pending = pending
        self.commit = commit
        self.commitPath = commitPath
        self.hooks = hooks
    }

    /// Moves `leaf` out of `parent` into the journal. `expected` is the identity the caller saw (scan time, or the
    /// live listing for keep-parent children). `clearImmutable` unlocks a user-owned `uchg` item that refuses to
    /// be renamed (Empty Trash).
    func detach(parent: Int32, parentPath: String, parentIdentity: FileIdentity, leaf: String,
                expected: FileIdentity, clearImmutable: Bool = false) -> DetachResult {
        var parentStat = stat()
        guard fstat(parent, &parentStat) == 0 else {
            return .skipped(.failed("fstat parent: errno \(errno)"), leftover: false)
        }
        // A rename can't cross devices; refuse up front (no `removefile` fallback on the original path: it
        // rebuilds paths through `F_GETPATH`, which the fd-relative design exists to avoid).
        guard parentStat.st_dev == stagingDev else {
            return .skipped(.stagingOtherVolume, leftover: false)
        }

        let id = UUID().uuidString
        let record = PendingRecord(parentPath: parentPath, parentIdentity: parentIdentity, name: leaf,
                                   identity: expected)
        if let failure = writeSidecar(record, id: id) {
            return .skipped(.failed("journal write: \(failure)"), leftover: false)
        }

        var attempt = 0
        while true {
            do {
                try CleanFS.exclusiveRename(fromDir: parent, leaf, toDir: pending.rawValue, id)
                break
            } catch {
                let code = error.errno ?? 0
                if code == EPERM, clearImmutable, attempt == 0, unlockImmutable(parent: parent, parentPath: parentPath,
                                                                               leaf: leaf) {
                    attempt += 1
                    continue
                }
                removeSidecar(id)
                switch code {
                case ENOENT: return .skipped(.vanished, leftover: false)
                case EXDEV: return .skipped(.stagingOtherVolume, leftover: false)
                // The flag is unknown on this kernel: fail closed rather than rename without symlink protection.
                case EINVAL: return .skipped(.failed("rename unsupported"), leftover: false)
                case EACCES, EPERM: return .skipped(.notPermitted, leftover: false)
                default: return .skipped(.failed("rename: \(String(cString: strerror(code)))"), leftover: false)
                }
            }
        }

        // From here the item lives in `pending/<id>`; a crash is repaired by `Staging.sweep`.
        if hooks.afterPendingRename?() == true {
            return .skipped(.failed("simulated crash"), leftover: true)
        }

        // The rename moved whatever the name pointed at *now*; make sure that is what the caller meant.
        let moved = try? pending.identity(of: id)
        guard moved == expected else {
            return rollBack(id: id, parent: parent, leaf: leaf)
        }
        do {
            try CleanFS.exclusiveRename(fromDir: pending.rawValue, id, toDir: commit.rawValue, id)
        } catch {
            DiskTools.log.error("staging: pending → commit failed for \(leaf, privacy: .public): \(error.errno ?? 0)")
            return .skipped(.failed("commit rename failed"), leftover: true)
        }
        removeSidecar(id)
        return .committed(CommittedEntry(name: id, identity: expected))
    }

    private func rollBack(id: String, parent: Int32, leaf: String) -> DetachResult {
        do {
            try CleanFS.exclusiveRename(fromDir: pending.rawValue, id, toDir: parent, leaf)
        } catch {
            let code = error.errno ?? 0
            DiskTools.log.error("staging: rollback of \(leaf, privacy: .public) failed, errno \(code); left in pending")
            // The original name was taken again (EEXIST) or the move back failed: the item must not be lost or
            // deleted, so it stays in `pending/` with its sidecar.
            return .skipped(code == EEXIST ? .rollbackCollision : .failed("rollback: \(String(cString: strerror(code)))"),
                            leftover: true)
        }
        removeSidecar(id)
        return .skipped(.changedSinceScan, leftover: false)
    }

    private func writeSidecar(_ record: PendingRecord, id: String) -> String? {
        let data: Data
        do { data = try JSONEncoder().encode(record) } catch { return "encode: \(error)" }
        let fd = openat(pending.rawValue, id + ".json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return "open: errno \(errno)" }
        defer { close(fd) }
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + written, data.count - written) }
            guard n > 0 else {
                unlinkat(pending.rawValue, id + ".json", 0)
                return "write: errno \(errno)"
            }
            written += n
        }
        // The sidecar must be durable before the item moves, or a crash could leave an unexplained pending entry.
        guard fsync(fd) == 0 else {
            unlinkat(pending.rawValue, id + ".json", 0)
            return "fsync: errno \(errno)"
        }
        return nil
    }

    private func removeSidecar(_ id: String) {
        if unlinkat(pending.rawValue, id + ".json", 0) != 0 && errno != ENOENT {
            // A leftover sidecar without an item is an orphan; the launch sweep removes it.
            DiskTools.log.error("staging: sidecar \(id, privacy: .public) not removed, errno \(errno)")
        }
    }

    /// Clears `UF_IMMUTABLE` on a user-owned item that can't be renamed. Accepted window: `lchflags` takes a path,
    /// so the name is re-resolved between the stat and the call; the item's identity is verified after the rename
    /// anyway, and the flag only matters inside the Trash (the only caller).
    private func unlockImmutable(parent: Int32, parentPath: String, leaf: String) -> Bool {
        guard let st = try? CleanFS.statAt(parent, leaf), st.st_uid == getuid(),
              st.st_flags & UInt32(UF_IMMUTABLE) != 0 else { return false }
        return lchflags(parentPath + "/" + leaf, st.st_flags & ~UInt32(UF_IMMUTABLE)) == 0
    }
}

public struct SweepReport: Equatable, Sendable {
    /// `commit/` entries deleted.
    public var deleted = 0
    /// `commit/` entries that could not be deleted (retried next launch).
    public var deleteFailures = 0
    /// Pending items put back at their original location.
    public var restored = 0
    /// Pending items that stay (name taken, parent changed, no sidecar): reported, never deleted.
    public var leftovers = 0
    /// Sidecars whose item was gone.
    public var orphanSidecars = 0
    /// The journal directories could not be opened.
    public var error: String?

    public init() {}
}

/// Owner of the staging directory (`staging/pending`, `staging/commit`, mode 0700, created on demand).
public final class Staging: Sendable {
    public let dir: String
    private let deleter: any Deleter

    public init(dir: String, deleter: (any Deleter)? = nil) {
        self.dir = dir
        self.deleter = deleter ?? DeleteWorker(slim: DeleteWorker.slimSupported(scratchIn: NSTemporaryDirectory()))
    }

    func openJournal(hooks: CleanTestHooks = CleanTestHooks(), create: Bool = true) throws(SafePathError) -> StagingJournal {
        if create { try CleanFS.makeDirectories(dir, mode: 0o700) }
        let root = try TrustedRoot(path: dir)
        for name in ["pending", "commit"] {
            try root.withDescriptor { (fd: Int32) throws(SafePathError) in
                if create, mkdirat(fd, name, 0o700) != 0 && errno != EEXIST {
                    throw .posix(op: "mkdirat \(name)", errno: errno)
                }
            }
        }
        let pending = try root.open(try RelativePath(validating: "pending"), flags: O_RDONLY | O_DIRECTORY)
        let commit = try root.open(try RelativePath(validating: "commit"), flags: O_RDONLY | O_DIRECTORY)
        return try StagingJournal(pending: pending, commit: commit, commitPath: root.canonicalPath + "/commit",
                                  hooks: hooks)
    }

    /// Launch recovery: delete `commit/*`; put `pending/*` items with a sidecar back (verifying the original
    /// parent's identity, never overwriting); report the rest. Nothing in `pending/` is ever deleted.
    public func sweep() -> SweepReport {
        sweep(hooks: CleanTestHooks())
    }

    func sweep(hooks: CleanTestHooks) -> SweepReport {
        var report = SweepReport()
        let journal: StagingJournal
        do {
            journal = try openJournal(hooks: hooks, create: false)
        } catch {
            // No staging directory yet means nothing to recover.
            if error.errno != ENOENT { report.error = "\(error)" }
            return report
        }
        sweepCommit(journal, &report)
        sweepPending(journal, &report)
        return report
    }

    private func sweepCommit(_ journal: StagingJournal, _ report: inout SweepReport) {
        let names: [String]
        do { names = try CleanFS.list(dirFd: journal.commit.rawValue).names } catch {
            report.error = "list commit: \(error)"
            return
        }
        for name in names {
            let outcome = deleter.delete(DeleteTarget(commitFd: journal.commit.rawValue, commitPath: journal.commitPath,
                                                      name: name), clearImmutable: false)
            if outcome.removed {
                report.deleted += 1
            } else {
                report.deleteFailures += 1
                DiskTools.log.error("staging sweep: commit/\(name, privacy: .public) not fully deleted: \(outcome.failures.joined(separator: "; "), privacy: .public)")
            }
        }
    }

    private func sweepPending(_ journal: StagingJournal, _ report: inout SweepReport) {
        let names: [String]
        do { names = try CleanFS.list(dirFd: journal.pending.rawValue).names } catch {
            report.error = "list pending: \(error)"
            return
        }
        let sidecars = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let items = Set(names.filter { !$0.hasSuffix(".json") })
        for id in items.subtracting(sidecars).sorted() {
            report.leftovers += 1
            DiskTools.log.error("staging sweep: pending/\(id, privacy: .public) has no sidecar; left in place")
        }
        for id in sidecars.sorted() {
            guard items.contains(id) else {
                if unlinkat(journal.pending.rawValue, id + ".json", 0) == 0 {
                    report.orphanSidecars += 1
                } else {
                    DiskTools.log.error("staging sweep: orphan sidecar \(id, privacy: .public) not removed, errno \(errno)")
                }
                continue
            }
            if restore(id: id, journal: journal) {
                report.restored += 1
            } else {
                report.leftovers += 1
            }
        }
    }

    private func restore(id: String, journal: StagingJournal) -> Bool {
        do {
            let fd = try FileDescriptor.open(at: journal.pending.rawValue, id + ".json",
                                             flags: O_RDONLY | O_NOFOLLOW)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd.rawValue, &buffer, buffer.count)
                guard n >= 0 else { throw SafePathError.posix(op: "read sidecar", errno: errno) }
                if n == 0 { break }
                data.append(contentsOf: buffer[0 ..< n])
            }
            let record = try JSONDecoder().decode(PendingRecord.self, from: data)
            let root = try TrustedRoot(path: record.parentPath)
            // The same directory the item was taken from, not just something spelled the same way now.
            guard root.identity == record.parentIdentity else {
                DiskTools.log.error("staging sweep: parent of pending/\(id, privacy: .public) changed; left in place")
                return false
            }
            guard try RelativePath(components: [record.name]).leaf == record.name else { return false }
            try root.withDescriptor { (parent: Int32) throws(SafePathError) in
                try CleanFS.exclusiveRename(fromDir: journal.pending.rawValue, id, toDir: parent, record.name)
            }
            if unlinkat(journal.pending.rawValue, id + ".json", 0) != 0 {
                DiskTools.log.error("staging sweep: sidecar \(id, privacy: .public) not removed, errno \(errno)")
            }
            DiskTools.log.notice("staging sweep: restored pending item to \(record.parentPath, privacy: .public)")
            return true
        } catch {
            // Name taken (EEXIST), parent gone, unreadable sidecar: the item stays in pending/ for the user.
            DiskTools.log.error("staging sweep: pending/\(id, privacy: .public) not restored: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
