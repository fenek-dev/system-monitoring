import Darwin
import Foundation
import Synchronization

/// An entry in `staging/commit/` to delete. `commitFd` is borrowed from the journal that owns it.
public struct DeleteTarget: Sendable {
    public var commitFd: Int32
    /// Canonical path of the commit directory: removefile reports failing paths as absolute canonical paths, and
    /// this prefix turns them back into fd-relative ones.
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
    /// Aborts deletions in flight (app quit). Entries stay in `commit/` and the next launch sweep finishes them.
    func cancelInFlight()
}

/// The `removefile` entry points, looked up at runtime: `removefile.h` is not part of the `Darwin` Swift module and
/// this target has no C module of its own.
struct RemoveFileFunctions: Sendable {
    typealias ErrorCallback = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32

    let stateAlloc: @convention(c) () -> OpaquePointer?
    let stateFree: @convention(c) (OpaquePointer?) -> Int32
    let stateSet: @convention(c) (OpaquePointer?, UInt32, UnsafeRawPointer?) -> Int32
    let stateGet: @convention(c) (OpaquePointer?, UInt32, UnsafeMutableRawPointer?) -> Int32
    let removeAt: @convention(c) (Int32, UnsafePointer<CChar>, OpaquePointer?, UInt32) -> Int32
    let cancel: @convention(c) (OpaquePointer?) -> Int32

    // removefile.h values.
    static let recursive: UInt32 = 1 << 0
    static let recursiveSlim: UInt32 = 1 << 11
    static let stateErrorCallback: UInt32 = 3
    static let stateErrorContext: UInt32 = 4
    static let stateErrno: UInt32 = 5
    static let skip: Int32 = 1

    static let live = RemoveFileFunctions()

    private init?() {
        // RTLD_DEFAULT
        let all = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(all, name).map { unsafeBitCast($0, to: type) }
        }
        guard let alloc = symbol("removefile_state_alloc", as: (@convention(c) () -> OpaquePointer?).self),
              let free = symbol("removefile_state_free", as: (@convention(c) (OpaquePointer?) -> Int32).self),
              let set = symbol("removefile_state_set",
                               as: (@convention(c) (OpaquePointer?, UInt32, UnsafeRawPointer?) -> Int32).self),
              let get = symbol("removefile_state_get",
                               as: (@convention(c) (OpaquePointer?, UInt32, UnsafeMutableRawPointer?) -> Int32).self),
              let removeAt = symbol("removefileat", as: (@convention(c) (Int32, UnsafePointer<CChar>, OpaquePointer?,
                                                                         UInt32) -> Int32).self),
              let cancel = symbol("removefile_cancel", as: (@convention(c) (OpaquePointer?) -> Int32).self)
        else { return nil }
        self.stateAlloc = alloc
        self.stateFree = free
        self.stateSet = set
        self.stateGet = get
        self.removeAt = removeAt
        self.cancel = cancel
    }
}

/// `removefileat` based deletion of `commit/` entries.
///
/// Only the error callback is installed: with `REMOVEFILE_RECURSIVE_SLIM`, confirm or status callbacks make the
/// call fail with `EINVAL` and remove nothing, and without an error callback the first failure aborts the whole
/// removal. The callback records each failing path and returns `SKIP`, so one locked file doesn't stop its siblings.
public final class DeleteWorker: Deleter {
    /// Collects failures reported through the C callback.
    private final class FailureLog: Sendable {
        struct Failure: Sendable { var path: String; var code: Int32 }
        let failures = Mutex<[Failure]>([])
    }

    private static let errorCallback: RemoveFileFunctions.ErrorCallback = { state, path, context in
        guard let context, let path, let state, let functions = RemoveFileFunctions.live else {
            return RemoveFileFunctions.skip
        }
        var code: Int32 = 0
        _ = functions.stateGet(state, RemoveFileFunctions.stateErrno, &code)
        let log = Unmanaged<FailureLog>.fromOpaque(context).takeUnretainedValue()
        log.failures.withLock { $0.append(FailureLog.Failure(path: String(cString: path), code: code)) }
        return RemoveFileFunctions.skip
    }

    /// Plain `RECURSIVE` instead of `RECURSIVE_SLIM` when a kernel doesn't know the flag.
    private let slim: Bool
    /// Raw addresses of in-flight states (for `cancelInFlight`); addresses, not pointers, so they are `Sendable`.
    private let inFlight = Mutex<Set<UInt>>([])
    /// Rounds of "fix permissions, retry" before giving up on a tree.
    private static let maxRounds = 5

    public init(slim: Bool) {
        self.slim = slim
    }

    /// Launch probe: deletes a scratch tree in `scratchDir` with `RECURSIVE_SLIM` + error callback only.
    /// `EINVAL` (flag unknown) or any failure → false.
    public static func slimSupported(scratchIn scratchDir: String) -> Bool {
        guard let functions = RemoveFileFunctions.live else { return false }
        var template = Array((scratchDir + "/slim-probe.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { return false }
        let probe = String(cString: created)
        let dir = open(probe, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { rmdir(probe); return false }
        defer { close(dir) }
        guard mkdirat(dir, "t", 0o700) == 0 else { rmdir(probe); return false }
        let file = openat(dir, "t/f", O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        if file >= 0 { close(file) }
        let log = FailureLog()
        let ok = remove("t", in: dir, functions: functions, flags: RemoveFileFunctions.recursive | RemoveFileFunctions.recursiveSlim,
                        log: log, register: { _ in }, unregister: { _ in }).rc == 0
        var st = stat()
        let gone = fstatat(dir, "t", &st, AT_SYMLINK_NOFOLLOW) != 0 && Darwin.errno == ENOENT
        // Leftovers of a failed probe are plain scratch; remove them the ordinary way.
        if !gone {
            _ = remove("t", in: dir, functions: functions, flags: RemoveFileFunctions.recursive, log: FailureLog(),
                       register: { _ in }, unregister: { _ in })
        }
        rmdir(probe)
        return ok && gone
    }

    public func delete(_ target: DeleteTarget, clearImmutable: Bool) -> DeleteOutcome {
        guard let functions = RemoveFileFunctions.live else {
            return DeleteOutcome(removed: false, failures: ["removefile unavailable"])
        }
        let flags = RemoveFileFunctions.recursive | (slim ? RemoveFileFunctions.recursiveSlim : 0)
        var failures: [FailureLog.Failure] = []
        for _ in 0 ..< Self.maxRounds {
            let log = FailureLog()
            _ = Self.remove(target.name, in: target.commitFd, functions: functions, flags: flags, log: log,
                            register: { address in inFlight.withLock { _ = $0.insert(address) } },
                            unregister: { address in inFlight.withLock { _ = $0.remove(address) } })
            failures = log.failures.withLock { $0 }
            // Residual check: the return value can be 0 with failures reported (SLIM), so only the entry's
            // absence counts as success.
            if !Self.exists(target.commitFd, target.name) { return DeleteOutcome(removed: true) }
            guard !failures.isEmpty, Self.repair(failures, target: target, clearImmutable: clearImmutable) else { break }
        }
        let lines = failures.map { "\($0.path): \(String(cString: strerror($0.code)))" }
        return DeleteOutcome(removed: !Self.exists(target.commitFd, target.name), failures: lines)
    }

    public func cancelInFlight() {
        guard let functions = RemoveFileFunctions.live else { return }
        for address in inFlight.withLock({ $0 }) {
            _ = functions.cancel(OpaquePointer(bitPattern: address))
        }
    }

    private static func exists(_ dir: Int32, _ name: String) -> Bool {
        var st = stat()
        return fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 || Darwin.errno != ENOENT
    }

    private static func remove(_ name: String, in dir: Int32, functions: RemoveFileFunctions, flags: UInt32,
                               log: FailureLog, register: (UInt) -> Void,
                               unregister: (UInt) -> Void) -> (rc: Int32, errno: Int32) {
        guard let state = functions.stateAlloc() else { return (-1, ENOMEM) }
        let address = UInt(bitPattern: state)
        register(address)
        defer {
            unregister(address)
            _ = functions.stateFree(state)
        }
        _ = functions.stateSet(state, RemoveFileFunctions.stateErrorCallback,
                               unsafeBitCast(errorCallback, to: UnsafeRawPointer.self))
        // `log` outlives the call: the callback only runs synchronously inside `removeAt`.
        _ = functions.stateSet(state, RemoveFileFunctions.stateErrorContext,
                               UnsafeRawPointer(Unmanaged.passUnretained(log).toOpaque()))
        let rc = functions.removeAt(dir, name, state, flags)
        var code: Int32 = 0
        _ = functions.stateGet(state, RemoveFileFunctions.stateErrno, &code)
        return (rc, code)
    }

    /// Makes the failing spots deletable. Everything touched is below `commit/` (our 0700 directory), so the
    /// path-based `lchflags` is safe from foreign symlinks. Returns whether anything changed (else retrying is
    /// pointless).
    private static func repair(_ failures: [FailureLog.Failure], target: DeleteTarget,
                               clearImmutable: Bool) -> Bool {
        var changed = false
        let uid = getuid()
        let prefix = target.commitPath + "/"
        for failure in failures where failure.code == EACCES || (clearImmutable && failure.code == EPERM) {
            guard failure.path.hasPrefix(prefix),
                  let rel = try? RelativePath(validating: String(failure.path.dropFirst(prefix.count))) else {
                continue
            }
            // Top-down: an ancestor without search permission would block the checks below it.
            for end in 1 ... rel.components.count {
                let part = rel.components.prefix(end).joined(separator: "/")
                guard var st = try? CleanFS.statAt(target.commitFd, part), st.st_uid == uid else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                if isDir, st.st_mode & 0o700 != 0o700 {
                    if fchmodat(target.commitFd, part, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) == 0 {
                        changed = true
                    }
                    guard let again = try? CleanFS.statAt(target.commitFd, part) else { continue }
                    st = again
                }
                if clearImmutable, st.st_flags & UInt32(UF_IMMUTABLE) != 0,
                   lchflags(prefix + part, st.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 {
                    changed = true
                }
            }
        }
        return changed
    }
}
