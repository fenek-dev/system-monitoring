import Darwin
import Foundation
import MonitorModel
import Synchronization

/// Test double: a tree literal served as listings. `onOpen` / `onList` run before each open / list call and may
/// sleep, block on a semaphore the test controls, or throw (`EACCES`, `ENXIO`). Counts opens and closes so tests
/// can assert that every handle was released.
public final class InMemoryLister: DirectoryLister {
    public struct Item: Sendable {
        public var entry: ListedEntry
        public var children: [Item]

        public static func dir(_ name: String, fileFlags: UInt32 = 0, mountStatus: UInt32 = 0, mtime: Int64 = 0,
                               _ children: [Item] = []) -> Item {
            Item(entry: ListedEntry(name: Array(name.utf8), kind: .directory, mtime: mtime, fileFlags: fileFlags,
                                    mountStatus: mountStatus),
                 children: children)
        }

        /// `fileID == nil` → a unique generated id; give the same id to the links of one inode.
        public static func file(_ name: String, _ bytes: UInt64, mtime: Int64 = 0, linkCount: UInt32 = 1,
                                fileID: UInt64? = nil, fileFlags: UInt32 = 0, privateBytes: UInt64? = nil) -> Item {
            Item(entry: ListedEntry(name: Array(name.utf8), kind: .regular, fileID: fileID ?? 0, mtime: mtime,
                                    fileFlags: fileFlags, linkCount: linkCount, allocBytes: bytes,
                                    privateBytes: privateBytes),
                 children: [])
        }

        public static func symlink(_ name: String) -> Item {
            Item(entry: ListedEntry(name: Array(name.utf8), kind: .symlink), children: [])
        }
    }

    public let info: ScanRootInfo
    public let opened = Atomic<Int>(0)
    public let closed = Atomic<Int>(0)
    /// Every path (components joined by "/", "" = root) whose listing was requested.
    public let listedPaths = Mutex<[String]>([])

    private let table: [String: [ListedEntry]]
    private let batchSize: Int
    private let onOpen: @Sendable (String) throws(ListError) -> Void
    private let onList: @Sendable (String) throws(ListError) -> Void

    public init(
        _ root: [Item], batchSize: Int = 1000,
        info: ScanRootInfo = ScanRootInfo(dev: 1, fileID: 1, mtime: 0, volumeUUID: nil),
        onOpen: @escaping @Sendable (String) throws(ListError) -> Void = { _ in },
        onList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in }
    ) {
        self.info = info
        self.batchSize = batchSize
        self.onOpen = onOpen
        self.onList = onList
        var table: [String: [ListedEntry]] = [:]
        var nextID: UInt64 = 1 << 20
        Self.flatten(root, at: "", into: &table, nextID: &nextID)
        self.table = table
    }

    public func rootInfo() throws(ListError) -> ScanRootInfo { info }

    public func open(_ rel: RelativePath?) throws(ListError) -> DirectoryHandle {
        let key = rel?.components.joined(separator: "/") ?? ""
        try onOpen(key)
        guard table[key] != nil else { throw ListError(errno: ENOENT, op: "open \(key)") }
        opened.add(1, ordering: .sequentiallyConsistent)
        return DirectoryHandle(fd: nil, path: key) { [self] _ in
            closed.add(1, ordering: .sequentiallyConsistent)
        }
    }

    public func list(_ dir: borrowing DirectoryHandle) throws(ListError) -> ListBatch {
        let key = dir.path
        try onList(key)
        listedPaths.withLock { $0.append(key) }
        let entries = table[key] ?? []
        let start = dir.cursor.load(ordering: .relaxed)
        let end = min(start + batchSize, entries.count)
        dir.cursor.store(end, ordering: .relaxed)
        return ListBatch(entries: Array(entries[start ..< end]), done: end >= entries.count)
    }

    public func attributes(of rel: RelativePath) throws(ListError) -> ListedEntry {
        let parent = rel.components.dropLast().joined(separator: "/")
        let name = Array(rel.leaf.utf8)
        guard let entry = table[parent]?.first(where: { $0.name == name }) else {
            throw ListError(errno: ENOENT, op: "attributes \(rel)")
        }
        return entry
    }

    private static func flatten(_ items: [Item], at path: String, into table: inout [String: [ListedEntry]],
                                nextID: inout UInt64) {
        var entries: [ListedEntry] = []
        for item in items {
            var entry = item.entry
            if entry.fileID == 0 {
                entry.fileID = nextID
                nextID += 1
            }
            entries.append(entry)
            if entry.kind == .directory {
                let name = String(decoding: entry.name, as: UTF8.self)
                flatten(item.children, at: path.isEmpty ? name : path + "/" + name, into: &table, nextID: &nextID)
            }
        }
        table[path] = entries
    }
}
