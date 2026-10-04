import CPrivate
import Darwin
import Foundation
import Synchronization

/// An entry in `staging/commit/` to delete. `commitFd` is borrowed from the journal that owns it.
public struct DeleteTarget: Sendable {
    public var commitFd: Int32
    /// Canonical path of the commit directory (kept for log context).
    public var commitPath: String
    public var name: String

    public init(commitFd: Int32, commitPath: String, name: String) {
        self.commitFd = commitFd
        self.commitPath = commitPath
        self.name = name
    }
}

public struct DeleteOutcome: Equatable, Sendable {
    /// True only if `commit/<name>` no longer exists afterwards. `removefile` can return 0 while its error
    /// callback saw failures, so the return value never decides this.
    public var removed: Bool
    /// `path: strerror` lines for what could not be deleted (logged by the caller).
    public var failures: [String]

    public init(removed: Bool, failures: [String] = []) {
        self.removed = removed
        self.failures = failures
    }
}

/// Deletes committed staging entries. Injected through `CleanContext` so tests can gate or fail deletions.
public protocol Deleter: Sendable {
    /// Blocks until the entry is gone or deleting it failed. `clearImmutable`: user-owned `uchg` files are
    /// unlocked and retried (Empty Trash only; a normal clean leaves them and reports a partial delete).
    func delete(_ target: DeleteTarget, clearImmutable: Bool) -> DeleteOutcome
    /// Aborts deletions in flight and refuses new ones (app quit). Entries stay in `commit/` and the next launch
    /// sweep finishes them.
    func cancelInFlight()
}

/// `removefileat` based deletion of `commit/` entries.
///
/// Only the error callback is installed: with `TT_REMOVEFILE_RECURSIVE_SLIM`, confirm or status callbacks make the
/// call fail with `EINVAL` and remove nothing, and without an error callback the first failure aborts the whole
/// removal. The callback records each failing path and returns `SKIP`, so one locked file doesn't stop its siblings.
public final class DeleteWorker: Deleter {
    /// Collects failures reported through the C callback.
    private final class FailureLog: Sendable {
        struct Failure: Sendable { var path: String; var code: Int32 }
        let failures = Mutex<[Failure]>([])
    }

    private static let errorCallback: tt_removefile_callback_t = { state, path, context in
        guard let context, let path, let state else { return Int32(TT_REMOVEFILE_SKIP) }
        var code: Int32 = 0
        _ = removefile_state_get(state, UInt32(TT_REMOVEFILE_STATE_ERRNO), &code)
        let log = Unmanaged<FailureLog>.fromOpaque(context).takeUnretainedValue()
        log.failures.withLock { $0.append(FailureLog.Failure(path: String(cString: path), code: code)) }
        return Int32(TT_REMOVEFILE_SKIP)
    }

    /// States in flight and the abort flag live under one lock: `removefile_cancel` only ever touches a state that
    /// is still registered, and a state is freed only after it left the set under the same lock (a cancel can't
    /// race the free).
    private struct Registry {
        var aborted = false
        var states: Set<UInt> = []
    }

    /// Plain `RECURSIVE` instead of `RECURSIVE_SLIM` when a kernel doesn't know the flag.
    private let slim: Bool
    private let registry = Mutex(Registry())
    /// Rounds of "fix permissions, retry" before giving up on a tree.
    private static let maxRounds = 5

    public init(slim: Bool) {
        self.slim = slim
    }

    /// Launch probe: deletes a scratch tree in `scratchDir` with `RECURSIVE_SLIM` + error callback only.
    /// `EINVAL` (flag unknown) or any failure → false.
    public static func slimSupported(scratchIn scratchDir: String) -> Bool {
        var template = Array((scratchDir + "/slim-probe.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { return false }
        let probe = String(cString: created)
        let dir = open(probe, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { rmdir(probe); return false }
        defer { close(dir) }
        guard mkdirat(dir, "t", 0o700) == 0 else { rmdir(probe); return false }
        let file = openat(dir, "t/f", O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        if file >= 0 { close(file) }
        let worker = DeleteWorker(slim: true)
        let ok = worker.attempt("t", in: dir, flags: UInt32(TT_REMOVEFILE_RECURSIVE | TT_REMOVEFILE_RECURSIVE_SLIM),
                                log: FailureLog()).rc == 0
        let gone = !exists(dir, "t")
        // Leftovers of a failed probe are plain scratch; remove them the ordinary way.
        if !gone { _ = worker.attempt("t", in: dir, flags: UInt32(TT_REMOVEFILE_RECURSIVE), log: FailureLog()) }
        rmdir(probe)
        return ok && gone
    }

    public func delete(_ target: DeleteTarget, clearImmutable: Bool) -> DeleteOutcome {
        // SLIM is a depth-first directory walk: on a plain file it fails with ENOTDIR (measured), so files and
        // symlinks use plain RECURSIVE.
        let entry = try? CleanFS.statAt(target.commitFd, target.name)
        let isDirectory = entry.map { ($0.st_mode & S_IFMT) == S_IFDIR } ?? false
        let flags = UInt32(TT_REMOVEFILE_RECURSIVE) | (slim && isDirectory ? UInt32(TT_REMOVEFILE_RECURSIVE_SLIM) : 0)
        var failures: [FailureLog.Failure] = []
        var last: (rc: Int32, errno: Int32) = (0, 0)
        var cancelled = false
        for _ in 0 ..< Self.maxRounds {
            let log = FailureLog()
            last = attempt(target.name, in: target.commitFd, flags: flags, log: log)
            failures = log.failures.withLock { $0 }
            // Residual check: the return value can be 0 with failures reported (SLIM), so only the entry's
            // absence counts as success.
            if !Self.exists(target.commitFd, target.name) { return DeleteOutcome(removed: true) }
            // ECANCELED / the abort flag stop everything: no repair, no further rounds.
            if last.errno == ECANCELED || registry.withLock({ $0.aborted }) {
                cancelled = true
                break
            }
            guard Self.repair(target: target, clearImmutable: clearImmutable, dev: entry?.st_dev) else { break }
        }
        var lines = failures.map { "\($0.path): \(String(cString: strerror($0.code)))" }
        if cancelled { lines.append("cancelled") }
        if lines.isEmpty {
            // Nothing was reported through the callback, yet the entry is still there: say what the call returned.
            lines.append("removefile returned \(last.rc), errno \(last.errno) (\(String(cString: strerror(last.errno)))); entry remains")
        }
        return DeleteOutcome(removed: !Self.exists(target.commitFd, target.name), failures: lines)
    }

    public func cancelInFlight() {
        registry.withLock { registry in
            registry.aborted = true
            for address in registry.states {
                _ = removefile_cancel(OpaquePointer(bitPattern: address))
            }
        }
    }

    private static func exists(_ dir: Int32, _ name: String) -> Bool {
        var st = stat()
        return fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 || Darwin.errno != ENOENT
    }

    private func attempt(_ name: String, in dir: Int32, flags: UInt32, log: FailureLog) -> (rc: Int32, errno: Int32) {
        guard let state = removefile_state_alloc() else { return (-1, ENOMEM) }
        let address = UInt(bitPattern: state)
        let registered = registry.withLock { registry -> Bool in
            guard !registry.aborted else { return false }
            registry.states.insert(address)
            return true
        }
        defer {
            // Leaves the set and is freed under the same lock `cancelInFlight` holds while it cancels.
            registry.withLock { registry in
                registry.states.remove(address)
                _ = removefile_state_free(state)
            }
        }
        guard registered else { return (-1, ECANCELED) }
        _ = removefile_state_set(state, UInt32(TT_REMOVEFILE_STATE_ERROR_CALLBACK),
                                 unsafeBitCast(Self.errorCallback, to: UnsafeRawPointer.self))
        // `log` outlives the call: the callback only runs synchronously inside `removefileat`.
        _ = removefile_state_set(state, UInt32(TT_REMOVEFILE_STATE_ERROR_CONTEXT),
                                 UnsafeRawPointer(Unmanaged.passUnretained(log).toOpaque()))
        let rc = removefileat(dir, name, state, flags)
        var code: Int32 = 0
        _ = removefile_state_get(state, UInt32(TT_REMOVEFILE_STATE_ERRNO), &code)
        return (rc, code)
    }

    /// Walks what is left of the entry and makes every user-owned directory accessible (and, for Empty Trash, clears
    /// `uchg`). A tree walk rather than the failing paths: `RECURSIVE_SLIM` silently skips directories it cannot
    /// read (measured: no callback for them), so the error list alone can miss them. Everything touched is below
    /// `commit/` (our 0700 directory), so the path-based `lchflags` can't be redirected by a foreign symlink, and
    /// nothing on another device (a mount inside the entry) is touched. Returns whether anything changed (else
    /// another attempt is pointless).
    static func repair(target: DeleteTarget, clearImmutable: Bool, dev: dev_t?) -> Bool {
        guard let dev else { return false }
        var changed = false
        repairEntry(in: target.commitFd, name: target.name, path: target.commitPath + "/" + target.name,
                    clearImmutable: clearImmutable, uid: getuid(), dev: dev, changed: &changed)
        return changed
    }

    private static func repairEntry(in dirFd: Int32, name: String, path: String, clearImmutable: Bool, uid: uid_t,
                                    dev: dev_t, changed: inout Bool) {
        guard var st = try? CleanFS.statAt(dirFd, name), st.st_uid == uid, st.st_dev == dev else { return }
        if clearImmutable, st.st_flags & UInt32(UF_IMMUTABLE) != 0,
           lchflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 {
            changed = true
            guard let again = try? CleanFS.statAt(dirFd, name) else { return }
            st = again
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return }
        if st.st_mode & 0o700 != 0o700 {
            guard fchmodat(dirFd, name, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) == 0 else { return }
            changed = true
        }
        guard let child = try? FileDescriptor.open(at: dirFd, name, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW),
              let listing = try? CleanFS.list(dirFd: child.rawValue) else { return }
        for entry in listing.names {
            repairEntry(in: child.rawValue, name: entry, path: path + "/" + entry, clearImmutable: clearImmutable,
                        uid: uid, dev: dev, changed: &changed)
        }
    }
}
