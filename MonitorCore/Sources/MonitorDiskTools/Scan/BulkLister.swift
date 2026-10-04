import Darwin
import Foundation
import MonitorModel
import Synchronization

/// Production lister: `getattrlistbulk` through fd-relative opens below a `TrustedRoot`.
///
/// Buffers are pooled (a fresh 256 KiB allocation per directory costs more than most listings); a buffer is only
/// held during one `list` call, so the pool never exceeds the number of concurrent workers.
public final class BulkLister: DirectoryLister {
    /// Spike §6: buffer size is irrelevant for speed; this bounds one batch.
    static let bufferSize = 256 * 1024

    private let root: TrustedRoot
    private let includePrivateSize: Bool
    /// Buffer base addresses (raw pointers are not `Sendable`); each is owned by exactly one `list` call or the pool.
    private let pool = Mutex<[Int]>([])

    public init(root: TrustedRoot, includePrivateSize: Bool = false) {
        self.root = root
        self.includePrivateSize = includePrivateSize
    }

    deinit {
        pool.withLock { addresses in
            for address in addresses { UnsafeMutableRawPointer(bitPattern: address)?.deallocate() }
        }
    }

    public func rootInfo() throws(ListError) -> ScanRootInfo {
        var st = stat()
        let rc = root.withDescriptor { fstat($0, &st) }
        guard rc == 0 else { throw ListError(errno: Darwin.errno, op: "fstat root") }
        return ScanRootInfo(dev: st.st_dev, fileID: st.st_ino, mtime: Int64(st.st_mtimespec.tv_sec),
                            volumeUUID: Self.volumeUUID(path: root.canonicalPath))
    }

    public func open(_ rel: RelativePath?) throws(ListError) -> DirectoryHandle {
        do throws(SafePathError) {
            let fd: FileDescriptor
            if let rel {
                fd = try root.open(rel, flags: O_RDONLY | O_DIRECTORY)
            } else {
                let copy = Darwin.fcntl(root.withDescriptor { $0 }, F_DUPFD_CLOEXEC, 0)
                guard copy >= 0 else { throw SafePathError.posix(op: "dup root", errno: Darwin.errno) }
                fd = FileDescriptor(adopting: copy)
            }
            return DirectoryHandle(fd: fd)
        } catch {
            throw ListError(error, op: "open \(rel?.description ?? "<root>")")
        }
    }

    public func list(_ dir: borrowing DirectoryHandle) throws(ListError) -> ListBatch {
        guard let raw = dir.rawFD else { throw ListError(errno: EBADF, op: "list") }
        let buffer = takeBuffer()
        defer { returnBuffer(buffer) }
        let entries = try BulkAttrParser.fetch(fd: raw, into: buffer, includePrivateSize: includePrivateSize)
        return ListBatch(entries: entries, done: entries.isEmpty)
    }

    public func attributes(of rel: RelativePath) throws(ListError) -> ListedEntry {
        let fd: FileDescriptor
        do {
            fd = try root.open(rel, flags: O_RDONLY)
        } catch {
            throw ListError(error, op: "open \(rel)")
        }
        var entry = try BulkAttrParser.fetchOne(fd: fd.rawValue, includePrivateSize: includePrivateSize)
        if entry.name.isEmpty { entry.name = Array(rel.leaf.utf8) }
        return entry
    }

    private func takeBuffer() -> UnsafeMutableRawBufferPointer {
        if let address = pool.withLock({ $0.popLast() }) {
            return UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: address),
                                                 count: Self.bufferSize)
        }
        return UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
    }

    private func returnBuffer(_ buffer: UnsafeMutableRawBufferPointer) {
        let address = Int(bitPattern: buffer.baseAddress)
        pool.withLock { $0.append(address) }
    }

    /// `ATTR_VOL_UUID` of the volume holding `path`; nil if the filesystem has none.
    static func volumeUUID(path: String) -> UUID? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = ATTR_VOL_INFO | attrgroup_t(ATTR_VOL_UUID)
        var reply = (UInt32(0), uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let rc = withUnsafeMutableBytes(of: &reply) { getattrlist(path, &list, $0.baseAddress, $0.count, 0) }
        guard rc == 0 else {
            DiskTools.log.error("ATTR_VOL_UUID for \(path) failed, errno \(Darwin.errno)")
            return nil
        }
        return UUID(uuid: reply.1)
    }
}
