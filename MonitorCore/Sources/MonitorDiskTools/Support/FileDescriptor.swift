import Darwin
import MonitorModel

public enum SafePathError: Error, Equatable, Sendable {
    /// The path spelling was rejected before touching the filesystem (`..`, `.`, empty component, NUL, absolute).
    case invalidPath(String)
    case outsideRoot
    /// A syscall failed: `ELOOP` (symlink), `ENOTCAPABLE` (escape), `ENOENT`, `EACCES`, …
    case posix(op: String, errno: Int32)

    public var errno: Int32? {
        if case let .posix(_, e) = self { return e }
        return nil
    }
}

/// Owns one open file descriptor and closes it when dropped. Noncopyable, so exactly one owner closes it; scanner
/// workers keep the fds they open and never hand them to another thread to close.
public struct FileDescriptor: ~Copyable, Sendable {
    public let rawValue: Int32

    public init(adopting rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        // A close failure on a descriptor we only read through leaves nothing to recover; the fd is released either way.
        _ = Darwin.close(rawValue)
    }

    /// `openat(dir, name, flags | O_CLOEXEC)`.
    public static func open(at dir: Int32, _ name: String, flags: Int32) throws(SafePathError) -> FileDescriptor {
        let fd = Darwin.openat(dir, name, flags | O_CLOEXEC)
        guard fd >= 0 else { throw .posix(op: "openat \(name)", errno: Darwin.errno) }
        return FileDescriptor(adopting: fd)
    }

    /// Gives up ownership without closing.
    public consuming func take() -> Int32 {
        let fd = rawValue
        discard self
        return fd
    }

    public func duplicate() throws(SafePathError) -> FileDescriptor {
        let fd = Darwin.fcntl(rawValue, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw .posix(op: "dup", errno: Darwin.errno) }
        return FileDescriptor(adopting: fd)
    }

    public func identity() throws(SafePathError) -> FileIdentity {
        var st = stat()
        guard Darwin.fstat(rawValue, &st) == 0 else { throw .posix(op: "fstat", errno: Darwin.errno) }
        return FileIdentity(st)
    }

    /// Identity of `name` inside this directory without following a final symlink.
    public func identity(of name: String) throws(SafePathError) -> FileIdentity {
        var st = stat()
        guard Darwin.fstatat(rawValue, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw .posix(op: "fstatat \(name)", errno: Darwin.errno)
        }
        return FileIdentity(st)
    }
}

extension FileIdentity {
    public init(_ st: stat) {
        self.init(dev: st.st_dev, ino: st.st_ino, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR)
    }
}
