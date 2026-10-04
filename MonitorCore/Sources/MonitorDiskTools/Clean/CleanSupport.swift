import Darwin
import Foundation
import MonitorModel

/// Test seams of the cleaner pipeline. Production code passes `CleanTestHooks()`.
struct CleanTestHooks: Sendable {
    /// Replaces the staging directory's device number (simulates staging on another volume).
    var stagingDeviceOverride: Int32?
    /// Called right after an item was renamed into `staging/pending`; `true` simulates a crash there.
    var afterPendingRename: (@Sendable () -> Bool)?
    /// Called before the cleaner looks at item `index` (cancel / ordering tests).
    var beforeItem: (@Sendable (Int) -> Void)?

    init(stagingDeviceOverride: Int32? = nil, afterPendingRename: (@Sendable () -> Bool)? = nil,
         beforeItem: (@Sendable (Int) -> Void)? = nil) {
        self.stagingDeviceOverride = stagingDeviceOverride
        self.afterPendingRename = afterPendingRename
        self.beforeItem = beforeItem
    }
}

/// fd-relative filesystem helpers shared by the cleaner pieces.
enum CleanFS {
    /// `renameatx_np` that never overwrites (`RENAME_EXCL`) and refuses symlinks anywhere in the path
    /// (`RENAME_NOFOLLOW_ANY`). Both names are leaves relative to their directory fds. `EEXIST` = name taken;
    /// `EINVAL` = flag unknown on this kernel, which callers treat as failure (fail closed), never as a reason to
    /// fall back to a path-based move.
    static func exclusiveRename(fromDir: Int32, _ from: String, toDir: Int32,
                                _ to: String) throws(SafePathError) {
        let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        guard renameatx_np(fromDir, from, toDir, to, flags) == 0 else {
            throw .posix(op: "renameatx_np \(from)", errno: Darwin.errno)
        }
    }

    /// Own descriptor for a borrowed one (a `TrustedRoot`'s), so the copy can be moved around and closed freely.
    static func duplicate(_ fd: Int32) throws(SafePathError) -> FileDescriptor {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw .posix(op: "dup", errno: Darwin.errno) }
        return FileDescriptor(adopting: copy)
    }

    /// nil when the name can't be stat'ed (callers treat that as "not the expected item").
    static func identity(of name: String, in dir: Int32) -> FileIdentity? {
        (try? statAt(dir, name)).map(FileIdentity.init)
    }

    static func statAt(_ dir: Int32, _ name: String) throws(SafePathError) -> stat {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw .posix(op: "fstatat \(name)", errno: Darwin.errno)
        }
        return st
    }

    /// Entries of the directory behind `dirFd`, read live. Names that are not valid UTF-8 can't round-trip through
    /// `String`, so they are counted in `unrepresentable` instead of being handed to path-taking calls (a mangled
    /// name would look like a vanished entry).
    static func list(dirFd: Int32) throws(SafePathError) -> (names: [String], unrepresentable: Int) {
        let dup = fcntl(dirFd, F_DUPFD_CLOEXEC, 0)
        guard dup >= 0 else { throw .posix(op: "dup", errno: Darwin.errno) }
        guard let dir = fdopendir(dup) else {
            let e = Darwin.errno
            close(dup)
            throw .posix(op: "fdopendir", errno: e)
        }
        defer { closedir(dir) }
        // The duplicate shares the file offset with `dirFd`: start from the beginning.
        rewinddir(dir)
        var names: [String] = []
        var unrepresentable = 0
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingCString: $0) }
            }
            guard let name else { unrepresentable += 1; continue }
            if name != "." && name != ".." { names.append(name) }
        }
        if errno != 0 { throw .posix(op: "readdir", errno: Darwin.errno) }
        return (names, unrepresentable)
    }

    /// `mkdir -p` for our own app-data directories (trusted input, never user-selected paths).
    static func makeDirectories(_ path: String, mode: mode_t) throws(SafePathError) {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if mkdir(current, mode) != 0 && Darwin.errno != EEXIST {
                throw .posix(op: "mkdir \(current)", errno: Darwin.errno)
            }
        }
    }

    /// A hard-linked file seen while measuring: the links met inside the measured entry and the file's total links.
    struct LinkSeen: Sendable, Equatable {
        var occurrences: Int
        var linkCount: UInt64
        var bytes: UInt64
    }

    /// Bytes of a measured entry. Hard-linked files are kept out of `bytes`: freeing one link frees nothing unless
    /// it was the last, which only the whole run can tell (`LinkLedger`).
    struct LiveSize: Sendable, Equatable {
        var bytes: UInt64 = 0
        var links: [FileIdentity: LinkSeen] = [:]
    }

    /// Allocated bytes under `name` (a file, or a directory walked live): `st_blocks * 512`. Unreadable
    /// subdirectories contribute 0: a best-effort figure for entries the scan never saw (created after the scan, or
    /// Trash contents), never a safety input.
    static func liveSize(dirFd: Int32, name: String) -> LiveSize {
        guard let st = try? statAt(dirFd, name) else { return LiveSize() }
        var size = LiveSize()
        measure(dirFd: dirFd, name: name, st: st, into: &size)
        return size
    }

    /// Total allocated bytes with every hard-linked file counted once (display figure for tests and logs).
    static func allocatedBytes(dirFd: Int32, name: String) -> UInt64 {
        let size = liveSize(dirFd: dirFd, name: name)
        return size.links.values.reduce(size.bytes) { $0 + $1.bytes }
    }

    private static func measure(dirFd: Int32, name: String, st: stat, into size: inout LiveSize) {
        let blocks = UInt64(max(0, st.st_blocks)) * 512
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        if st.st_nlink > 1 && !isDirectory {
            var seen = size.links[FileIdentity(st)] ?? LinkSeen(occurrences: 0, linkCount: 0, bytes: blocks)
            seen.occurrences += 1
            seen.linkCount = max(seen.linkCount, UInt64(st.st_nlink))
            size.links[FileIdentity(st)] = seen
        } else {
            size.bytes += blocks
        }
        guard isDirectory,
              let child = try? FileDescriptor.open(at: dirFd, name, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW),
              let listing = try? list(dirFd: child.rawValue) else { return }
        for entry in listing.names {
            guard let entrySt = try? statAt(child.rawValue, entry) else { continue }
            measure(dirFd: child.rawValue, name: entry, st: entrySt, into: &size)
        }
    }

    /// Maps a failed fd-relative open of a target to the reason the item is skipped.
    static func skipReason(for error: SafePathError) -> SkipReason {
        switch error {
        case .outsideRoot, .invalidPath:
            return .denied(.outsideRoot)
        case let .posix(op, code):
            switch code {
            case ENOENT: return .vanished
            case ENOTDIR: return .changedSinceScan
            // A symlink component, or the kernel refusing to resolve beneath the root.
            case ELOOP, ENOTCAPABLE: return .denied(.outsideRoot)
            // An ancestor we may not search: the identity chain can't be established.
            case EACCES, EPERM: return .denied(.unverifiable)
            default: return .failed("\(op): \(String(cString: strerror(code)))")
            }
        }
    }
}
