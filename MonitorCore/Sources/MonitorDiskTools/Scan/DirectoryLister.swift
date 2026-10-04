import Foundation
import MonitorModel
import Synchronization

/// `getattrlistbulk` object types (`fsobj_type_t`), reduced to what the walker distinguishes.
public enum ListedKind: Sendable, Equatable {
    case regular, directory, symlink, other
}

/// One directory entry as the walker needs it. `errorCode != 0` means the kernel could not read this entry's
/// attributes (every other field is then unreliable).
public struct ListedEntry: Sendable, Equatable {
    public var name: [UInt8]
    public var kind: ListedKind
    public var fileID: UInt64
    /// Seconds since 1970.
    public var mtime: Int64
    public var addedTime: Int64
    /// `st_flags` (`ATTR_CMN_FLAGS`): `UF_HIDDEN`, `SF_DATALESS`, …
    public var fileFlags: UInt32
    /// `ATTR_DIR_MOUNTSTATUS` (`DIR_MNTSTATUS_MNTPOINT` / `_TRIGGER`), 0 for non-directories.
    public var mountStatus: UInt32
    public var linkCount: UInt32
    public var allocBytes: UInt64
    /// `ATTR_CMNEXT_PRIVATESIZE` when the listing returned it.
    public var privateBytes: UInt64?
    public var errorCode: Int32

    public init(name: [UInt8], kind: ListedKind, fileID: UInt64 = 0, mtime: Int64 = 0, addedTime: Int64 = 0,
                fileFlags: UInt32 = 0, mountStatus: UInt32 = 0, linkCount: UInt32 = 1, allocBytes: UInt64 = 0,
                privateBytes: UInt64? = nil, errorCode: Int32 = 0) {
        self.name = name
        self.kind = kind
        self.fileID = fileID
        self.mtime = mtime
        self.addedTime = addedTime
        self.fileFlags = fileFlags
        self.mountStatus = mountStatus
        self.linkCount = linkCount
        self.allocBytes = allocBytes
        self.privateBytes = privateBytes
        self.errorCode = errorCode
    }
}

public struct ListBatch: Sendable {
    public var entries: [ListedEntry]
    /// No more entries: the next `list` call on the same handle would return nothing.
    public var done: Bool

    public init(entries: [ListedEntry], done: Bool) {
        self.entries = entries
        self.done = done
    }
}

/// A failed open/list. `errno` drives the walker's policy (`EACCES` → restricted node, `ENXIO` → volume gone).
public struct ListError: Error, Equatable, Sendable {
    public var errno: Int32
    public var op: String

    public init(errno: Int32, op: String) {
        self.errno = errno
        self.op = op
    }

    init(_ error: SafePathError, op: String) {
        self.init(errno: error.errno ?? EINVAL, op: op)
    }
}

/// Facts about the scan root's directory, read once per scan.
public struct ScanRootInfo: Sendable, Equatable {
    public var dev: Int32
    public var fileID: UInt64
    public var mtime: Int64
    public var volumeUUID: UUID?

    public init(dev: Int32, fileID: UInt64, mtime: Int64, volumeUUID: UUID?) {
        self.dev = dev
        self.fileID = fileID
        self.mtime = mtime
        self.volumeUUID = volumeUUID
    }
}

/// An open directory. Noncopyable: the worker that opened it closes it (drop = close + `onClose`), and it never
/// crosses threads. `token` / `path` / `cursor` are the lister's own bookkeeping.
public struct DirectoryHandle: ~Copyable, Sendable {
    private let fd: FileDescriptor?
    /// The descriptor's number, nil for listers without one.
    public let rawFD: Int32?
    public let path: String
    public let token: Int
    /// Batch position for listers that page by index.
    public let cursor = Atomic<Int>(0)
    private let onClose: (@Sendable (Int) -> Void)?

    public init(fd: consuming FileDescriptor?, path: String = "", token: Int = 0,
                onClose: (@Sendable (Int) -> Void)? = nil) {
        self.rawFD = fd?.rawValue
        self.fd = fd
        self.path = path
        self.token = token
        self.onClose = onClose
    }

    deinit {
        onClose?(token)
    }
}

/// Source of directory entries below one scan root. Production: `BulkLister`; tests: `InMemoryLister`.
public protocol DirectoryLister: Sendable {
    func rootInfo() throws(ListError) -> ScanRootInfo
    /// Opens a directory below the root (`nil` = the root itself). Never follows symlinks.
    func open(_ rel: RelativePath?) throws(ListError) -> DirectoryHandle
    /// The next batch of `dir`'s entries; bulk calls continue where the previous one stopped. A batch is bounded
    /// by the lister's buffer, so a huge directory arrives in several calls.
    func list(_ dir: borrowing DirectoryHandle) throws(ListError) -> ListBatch
    /// Attributes of one entry below the root (single files of the private-size pass).
    func attributes(of rel: RelativePath) throws(ListError) -> ListedEntry
}
