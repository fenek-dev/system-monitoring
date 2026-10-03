import Foundation
import MonitorModel

/// Declarative trees for DiskTools tests, built through the real `StorageTreeBuilder`: breadth-first, so each
/// directory's children are one contiguous batch, as the scanner commits them. Every node gets a unique `fileID`.
///
///     let tree = TreeFixture.build([
///         .dir("Library", [.dir("Caches", [.file("blob", 4_000_000), .small(bytes: 300, count: 3)])]),
///         .link("a", ino: 7, linkCount: 2, bytes: 1_000_000),
///     ])
///     let caches = tree.lookup(path: "/Users/test/Library/Caches")
enum TreeFixture {
    indirect enum Entry {
        case dir(String, flags: StorageNodeFlags, markers: StorageMarker, mtime: Int64, children: [Entry])
        case file(String, bytes: UInt64, mtime: Int64, added: Int64, flags: StorageNodeFlags)
        /// Small files folded into the enclosing directory.
        case small(bytes: UInt64, count: UInt32, maxMtime: Int64)
        /// One link of a hard-linked file: a kept file node when `name` is set, else folded into the directory.
        case link(String?, ino: UInt64, linkCount: UInt16, bytes: UInt64)
        case restricted(String)
    }

    static let defaultRoot = ScanRoot.home("/Users/test")
    static let dev: Int32 = 1

    static func dir(_ name: String, flags: StorageNodeFlags = [], markers: StorageMarker = [], mtime: Int64 = 0,
                    _ children: [Entry] = []) -> Entry {
        .dir(name, flags: flags, markers: markers, mtime: mtime, children: children)
    }

    static func file(_ name: String, _ bytes: UInt64, mtime: Int64 = 0, added: Int64 = 0,
                     flags: StorageNodeFlags = []) -> Entry {
        .file(name, bytes: bytes, mtime: mtime, added: added, flags: flags)
    }

    static func small(bytes: UInt64, count: UInt32 = 1, maxMtime: Int64 = 0) -> Entry {
        .small(bytes: bytes, count: count, maxMtime: maxMtime)
    }

    static func link(_ name: String?, ino: UInt64, linkCount: UInt16 = 2, bytes: UInt64) -> Entry {
        .link(name, ino: ino, linkCount: linkCount, bytes: bytes)
    }

    static func builder(root: ScanRoot = defaultRoot, _ entries: [Entry]) -> StorageTreeBuilder {
        var builder = StorageTreeBuilder(root: root, dev: dev, volumeUUID: nil, rootFileID: 1)
        var nextFileID: UInt64 = 2
        var queue: [(StorageNodeID, [Entry])] = [(0, entries)]
        while !queue.isEmpty {
            let (node, children) = queue.removeFirst()
            var records: [NodeRecord] = []
            var pending: [(index: Int, entry: Entry)] = []
            for entry in children {
                let id = nextFileID
                switch entry {
                case let .dir(name, flags, _, mtime, _):
                    records.append(NodeRecord(name: name, flags: flags.union(.directory), allocBytes: 0, fileID: id,
                                              mtime: mtime, addedTime: 0))
                case let .file(name, bytes, mtime, added, flags):
                    records.append(NodeRecord(name: name, flags: flags, allocBytes: bytes, fileID: id, mtime: mtime,
                                              addedTime: added))
                case let .link(name?, _, _, _):
                    records.append(NodeRecord(name: name, flags: [], allocBytes: 0, fileID: id, mtime: 0,
                                              addedTime: 0))
                case let .restricted(name):
                    records.append(NodeRecord(name: name, flags: [.directory], allocBytes: 0, fileID: id, mtime: 0,
                                              addedTime: 0))
                case let .small(bytes, count, maxMtime):
                    builder.addSmall(node, bytes: bytes, count: count, maxMtime: maxMtime)
                    continue
                case let .link(nil, ino, linkCount, bytes):
                    builder.addLink(FileIdentity(dev: dev, ino: ino, isDirectory: false), linkCount: linkCount,
                                    bytes: bytes, occurrence: node)
                    continue
                }
                nextFileID += 1
                pending.append((records.count - 1, entry))
            }
            let range = builder.appendChildren(of: node, records)
            for (index, entry) in pending {
                let child = range.lowerBound + Int32(index)
                switch entry {
                case let .dir(_, flags, markers, _, grandchildren):
                    builder.setDirFacts(child, markers: markers, flags: flags)
                    queue.append((child, grandchildren))
                case .restricted:
                    builder.setRestricted(child)
                case let .link(_, ino, linkCount, bytes):
                    builder.addLink(FileIdentity(dev: dev, ino: ino, isDirectory: false), linkCount: linkCount,
                                    bytes: bytes, occurrence: child)
                case .file, .small:
                    break
                }
            }
        }
        return builder
    }

    static func build(root: ScanRoot = defaultRoot, _ entries: [Entry],
                      scanDate: Date = Date(timeIntervalSince1970: 0)) -> StorageTree {
        builder(root: root, entries).finalize(scanDate: scanDate, lastEventId: 0)
    }
}
