import Darwin
import Foundation
import MonitorModel
import Synchronization

/// Production lister: `getattrlistbulk` through fd-relative opens below a `TrustedRoot`.
///
/// The root is opened by `rootInfo()` and closed by `release()`, so a finished or unmounted scan holds no
/// descriptor on the volume. Buffers are pooled (a fresh 256 KiB allocation per directory costs more than most
/// listings); a buffer is only held during one `list` call, so the pool never exceeds the number of workers.
public final class BulkLister: DirectoryLister {
    /// Spike §6: buffer size is irrelevant for speed; this bounds one batch.
    static let bufferSize = 256 * 1024

    private let rootPath: String
    private let includePrivateSize: Bool
    private struct RootState {
        var opened: TrustedRoot?
        var users = 0
    }

    private let root = Mutex(RootState())
    /// Buffer base addresses (raw pointers are not `Sendable`); each is owned by exactly one `list` call or the pool.
    private let pool = Mutex<[Int]>([])

    public init(rootPath: String, includePrivateSize: Bool = false) {
        self.rootPath = rootPath
        self.includePrivateSize = includePrivateSize
    }

    deinit {
        pool.withLock { addresses in
            for address in addresses { UnsafeMutableRawPointer(bitPattern: address)?.deallocate() }
        }
    }

    /// The open root's descriptor number (nil when released); lifecycle tests watch it.
    var rootDescriptor: Int32? { root.withLock { $0.opened?.withDescriptor { $0 } } }

    public func rootInfo() throws(ListError) -> ScanRootInfo {
        let opened: TrustedRoot
        do {
            opened = try TrustedRoot(path: rootPath)
        } catch {
            throw ListError(error, op: "open root \(rootPath)")
        }
        var st = stat()
        guard opened.withDescriptor({ fstat($0, &st) }) == 0 else {
            throw ListError(errno: Darwin.errno, op: "fstat root")
        }
        // Counted: a new scan may start before the previous one has released (it ends once its workers return).
        root.withLock { state in
            if state.opened == nil { state.opened = opened }
            state.users += 1
        }
        return ScanRootInfo(dev: st.st_dev, fileID: st.st_ino, mtime: Int64(st.st_mtimespec.tv_sec),
                            volumeUUID: Self.volumeUUID(path: opened.canonicalPath))
    }

    public func release() {
        root.withLock { state in
            state.users = max(0, state.users - 1)
            if state.users == 0 { state.opened = nil }
        }
    }

    private func openRoot() throws(ListError) -> TrustedRoot {
        guard let opened = root.withLock({ $0.opened }) else { throw ListError(errno: EBADF, op: "root not open") }
        return opened
    }

    public func open(_ rel: RelativePath?) throws(ListError) -> DirectoryHandle {
        let trusted = try openRoot()
        do throws(SafePathError) {
            let fd: FileDescriptor
            if let rel {
                fd = try trusted.open(rel, flags: O_RDONLY | O_DIRECTORY)
            } else {
                // A fresh open file description per listing: a dup of the root descriptor shares its directory
                // cursor, so a second listing (or an overlapping one) would start where the first stopped.
                fd = try FileDescriptor.open(at: trusted.withDescriptor { $0 }, ".",
                                             flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
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
        let trusted = try openRoot()
        let opened: TrustedRoot.OpenedParent
        do {
            opened = try trusted.openParent(rel)
        } catch {
            throw ListError(error, op: "open parent of \(rel)")
        }
        return try BulkAttrParser.fetchOne(parent: opened.parent.rawValue, name: opened.leaf,
                                           includePrivateSize: includePrivateSize)
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
