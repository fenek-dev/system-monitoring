import Darwin
import Foundation
import MonitorModel

/// Reference lister on `FileManager` + `lstat`: the oracle the bulk lister is compared against in the hardware
/// smoke test. Slow and path-based; never used by the app.
public final class FileManagerLister: DirectoryLister {
    private let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    public func rootInfo() throws(ListError) -> ScanRootInfo {
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ListError(errno: Darwin.errno, op: "lstat root") }
        return ScanRootInfo(dev: st.st_dev, fileID: st.st_ino, mtime: Int64(st.st_mtimespec.tv_sec),
                            volumeUUID: BulkLister.volumeUUID(path: rootPath))
    }

    public func open(_ rel: RelativePath?) throws(ListError) -> DirectoryHandle {
        let path = absolute(rel)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ListError(errno: Darwin.errno, op: "lstat \(path)") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ListError(errno: ENOTDIR, op: "open \(path)") }
        return DirectoryHandle(fd: nil, path: path)
    }

    public func list(_ dir: borrowing DirectoryHandle) throws(ListError) -> ListBatch {
        guard dir.cursor.load(ordering: .relaxed) == 0 else { return ListBatch(entries: [], done: true) }
        dir.cursor.store(1, ordering: .relaxed)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw ListError(errno: (error as NSError).code == NSFileReadNoPermissionError ? EACCES : EIO,
                            op: "contentsOfDirectory \(dir.path)")
        }
        return ListBatch(entries: try names.map { name throws(ListError) in
            try Self.entry(at: dir.path + "/" + name, name: name)
        }, done: true)
    }

    public func attributes(of rel: RelativePath) throws(ListError) -> ListedEntry {
        let path = absolute(rel)
        return try Self.entry(at: path, name: rel.leaf)
    }

    private func absolute(_ rel: RelativePath?) -> String {
        guard let rel else { return rootPath }
        return (rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath) + "/" + rel.description
    }

    private static func entry(at path: String, name: String) throws(ListError) -> ListedEntry {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ListError(errno: Darwin.errno, op: "lstat \(path)") }
        let kind: ListedKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return ListedEntry(
            name: Array(name.utf8), kind: kind, fileID: st.st_ino, mtime: Int64(st.st_mtimespec.tv_sec),
            fileFlags: st.st_flags, linkCount: UInt32(st.st_nlink), allocBytes: UInt64(st.st_blocks) * 512
        )
    }
}
