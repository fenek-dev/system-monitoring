import Darwin
import Foundation
import MonitorModel

public struct ScanCacheError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// On-disk copy of the last complete scan per (volume, root) so the app opens with a tree instead of a rescan.
///
/// File `storage-scan-<fnv1a64(uuid + root path)>.bin`: magic, schema, JSON header (identity, counts), then the
/// tree's arrays as raw little-endian sections, 8-byte aligned. Written to a temp file and renamed into place; read
/// through a memory map with every count and length checked against the file size first, and the tree's structural
/// invariants checked before it is built. Anything off deletes the file and reads as a miss.
///
/// The overlay (cleanup changes since the scan) lives beside it as `<same name>.overlay.json`.
public final class ScanCache: Sendable {
    /// Bump when the layout changes: older files read as a miss.
    public static let schema: UInt32 = 1

    private static let magic = Array("TTSCACHE".utf8)
    private static let prefixLength = 16 // magic + schema + header length

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Stores a **complete** scan. Never call it for a partial, cancelled or failed scan: a half tree would be
    /// loaded as truth on the next launch. Replacing the tree drops the overlay recorded against the previous scan.
    public func save(_ tree: StorageTree) throws(ScanCacheError) {
        let data = try Self.encode(tree)
        let url = treeURL(root: tree.root, volumeUUID: tree.volumeUUID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScanCacheError("write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        remove(overlayURL(for: url))
    }

    public func saveOverlay(_ overlay: StorageTreeOverlay) throws(ScanCacheError) {
        let url = overlayURL(for: treeURL(root: overlay.scan.root, volumeUUID: overlay.scan.volumeUUID))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(overlay).write(to: url, options: .atomic)
        } catch {
            throw ScanCacheError("write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The cached tree with its overlay (rebased onto the loaded tree; a fresh one when there is none or it no
    /// longer matches), or nil if there is no valid cache for this root and volume.
    public func load(root: ScanRoot, volumeUUID: UUID?) -> (tree: StorageTree, overlay: StorageTreeOverlay)? {
        let url = treeURL(root: root, volumeUUID: volumeUUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let tree: StorageTree
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            tree = try Self.decode(data, expectedRoot: root, expectedVolume: volumeUUID)
        } catch {
            DiskTools.log.error("scan cache \(url.lastPathComponent) rejected: \(String(describing: error))")
            remove(url)
            return nil
        }
        return (tree, loadOverlay(for: url, tree: tree))
    }

    // MARK: - Files

    func treeURL(root: ScanRoot, volumeUUID: UUID?) -> URL {
        // The root kind is part of the key: `.home(p)` and `.folder(p)` are different scans of the same path, and
        // sharing a file would make each one's load delete the other's cache as a mismatch.
        let kind: String
        switch root {
        case .home: kind = "home"
        case .folder: kind = "folder"
        case .volume: kind = "volume"
        }
        let key = Self.fnv1a64(Array(((volumeUUID?.uuidString ?? "") + kind + root.path).utf8))
        return directory.appendingPathComponent("storage-scan-\(String(key, radix: 16)).bin")
    }

    private func overlayURL(for treeURL: URL) -> URL {
        treeURL.deletingPathExtension().appendingPathExtension("overlay.json")
    }

    private func loadOverlay(for treeURL: URL, tree: StorageTree) -> StorageTreeOverlay {
        let url = overlayURL(for: treeURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return StorageTreeOverlay(tree: tree) }
        do {
            return try JSONDecoder().decode(StorageTreeOverlay.self, from: Data(contentsOf: url)).rebased(onto: tree)
        } catch {
            DiskTools.log.error("overlay sidecar \(url.lastPathComponent) rejected: \(String(describing: error))")
            remove(url)
            return StorageTreeOverlay(tree: tree)
        }
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            DiskTools.log.error("could not delete \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return hash
    }

    // MARK: - Format

    private struct Header: Codable {
        var root: ScanRoot
        var volumeUUID: UUID?
        var dev: Int32
        /// Bit pattern of `scanDate.timeIntervalSinceReferenceDate`: overlay rebasing compares dates for equality.
        var scanDateBits: UInt64
        var lastEventId: UInt64
        var nodeCount: Int
        var namesCount: Int
        var linkGroupCount: Int
        var occurrenceCount: Int
    }

    /// Link group on disk: dev, linkCount, flags (bit 0 directory, bit 1 has private, bits 2-3 provenance),
    /// pad, ino, alloc, private, first occurrence, occurrence count.
    private struct LinkRecord {
        var dev: Int32
        var linkCount: UInt16
        var flags: UInt8
        var pad: UInt8
        var ino: UInt64
        var allocBytes: UInt64
        var privateBytes: UInt64
        var firstOccurrence: UInt32
        var occurrenceCount: UInt32
    }

    private struct OccurrenceRecord {
        var node: Int32
        var depth: Int32
        var folded: UInt8
        var pad: (UInt8, UInt8, UInt8)
    }

    private static let provenanceByCode: [SizeProvenance] = [.exact, .estimate, .unavailable]

    private static func encode(_ tree: StorageTree) throws(ScanCacheError) -> Data {
        var records: [LinkRecord] = []
        var occurrences: [OccurrenceRecord] = []
        for group in tree.linkGroups {
            var flags: UInt8 = 0
            if group.identity.isDirectory { flags |= 1 }
            if group.privateBytes != nil { flags |= 2 }
            flags |= UInt8(provenanceByCode.firstIndex(of: group.provenance) ?? 1) << 2
            records.append(LinkRecord(
                dev: group.identity.dev, linkCount: group.linkCount, flags: flags, pad: 0, ino: group.identity.ino,
                allocBytes: group.allocBytes, privateBytes: group.privateBytes ?? 0,
                firstOccurrence: UInt32(occurrences.count), occurrenceCount: UInt32(group.occurrences.count)
            ))
            for occurrence in group.occurrences {
                occurrences.append(OccurrenceRecord(node: occurrence.node, depth: occurrence.depth,
                                                    folded: occurrence.isFolded ? 1 : 0, pad: (0, 0, 0)))
            }
        }
        let header = Header(
            root: tree.root, volumeUUID: tree.volumeUUID, dev: tree.dev,
            scanDateBits: tree.scanDate.timeIntervalSinceReferenceDate.bitPattern, lastEventId: tree.lastEventId,
            nodeCount: tree.nodeCount, namesCount: tree.names.count, linkGroupCount: records.count,
            occurrenceCount: occurrences.count
        )
        let headerJSON: Data
        do {
            headerJSON = try JSONEncoder().encode(header)
        } catch {
            throw ScanCacheError("header: \(error)")
        }

        var out = Data()
        out.reserveCapacity(prefixLength + headerJSON.count + tree.nodeCount * 120 + tree.names.count)
        out.append(contentsOf: magic)
        append(UInt32(schema), to: &out)
        append(UInt32(headerJSON.count), to: &out)
        out.append(headerJSON)
        pad(&out)
        // Wider elements first; every section stays 8-byte aligned.
        section(tree.allocBytes, &out); section(tree.smallBytes, &out); section(tree.fileID, &out)
        section(tree.mtime, &out); section(tree.subtreeMaxMtime, &out); section(tree.addedTime, &out)
        section(tree.childPrefix, &out)
        section(tree.parent, &out); section(tree.firstChild, &out); section(tree.childCount, &out)
        section(tree.smallCount, &out); section(tree.nameOffset, &out); section(tree.childOrder, &out)
        section(tree.markerMask.map(\.rawValue), &out)
        section(tree.flags.map(\.rawValue), &out); section(tree.nameLength, &out)
        section(tree.names, &out)
        section(records, &out); section(occurrences, &out)
        return out
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func pad(_ data: inout Data) {
        let remainder = data.count % 8
        if remainder != 0 { data.append(contentsOf: [UInt8](repeating: 0, count: 8 - remainder)) }
    }

    private static func section<T>(_ array: [T], _ data: inout Data) {
        array.withUnsafeBytes { data.append(contentsOf: $0) }
        pad(&data)
    }

    // MARK: Decoding

    private struct Reader {
        let data: Data
        var offset: Int

        /// `count` elements of `T` from the current section; the section must lie inside the file.
        mutating func array<T>(_: T.Type, count: Int) throws(ScanCacheError) -> [T] {
            let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
            guard count >= 0, !overflow, bytes <= data.count - offset else {
                throw ScanCacheError("section of \(count) × \(MemoryLayout<T>.stride) bytes exceeds file")
            }
            let start = offset
            let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    if bytes > 0 {
                        _ = memcpy(buffer.baseAddress, raw.baseAddress! + start, bytes)
                    }
                }
                initialized = count
            }
            offset += (bytes + 7) / 8 * 8
            guard offset <= data.count else { throw ScanCacheError("section padding exceeds file") }
            return result
        }
    }

    private static func decode(_ data: Data, expectedRoot: ScanRoot,
                               expectedVolume: UUID?) throws(ScanCacheError) -> StorageTree {
        guard data.count >= prefixLength, data.prefix(magic.count).elementsEqual(magic) else {
            throw ScanCacheError("bad magic")
        }
        let schemaValue = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        guard UInt32(littleEndian: schemaValue) == schema else { throw ScanCacheError("schema \(schemaValue)") }
        let headerLength = Int(UInt32(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        }))
        guard headerLength <= data.count - prefixLength else { throw ScanCacheError("header exceeds file") }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data.subdata(in: prefixLength ..< prefixLength + headerLength))
        } catch {
            throw ScanCacheError("header: \(error)")
        }
        guard header.root == expectedRoot, header.volumeUUID == expectedVolume else {
            throw ScanCacheError("belongs to another root or volume")
        }
        let n = header.nodeCount
        // 8 + 8 + … bytes per node alone exceed the file if the count lies; reject before allocating.
        guard n > 0, n <= data.count / 64, header.namesCount >= 0, header.namesCount <= data.count,
              header.linkGroupCount >= 0, header.occurrenceCount >= 0 else {
            throw ScanCacheError("implausible counts")
        }

        var reader = Reader(data: data, offset: (prefixLength + headerLength + 7) / 8 * 8)
        let allocBytes = try reader.array(UInt64.self, count: n)
        let smallBytes = try reader.array(UInt64.self, count: n)
        let fileID = try reader.array(UInt64.self, count: n)
        let mtime = try reader.array(Int64.self, count: n)
        let subtreeMaxMtime = try reader.array(Int64.self, count: n)
        let addedTime = try reader.array(Int64.self, count: n)
        let childPrefix = try reader.array(UInt64.self, count: n)
        let parent = try reader.array(Int32.self, count: n)
        let firstChild = try reader.array(Int32.self, count: n)
        let childCount = try reader.array(Int32.self, count: n)
        let smallCount = try reader.array(UInt32.self, count: n)
        let nameOffset = try reader.array(UInt32.self, count: n)
        let childOrder = try reader.array(Int32.self, count: n)
        let markers = try reader.array(UInt32.self, count: n)
        let flags = try reader.array(UInt16.self, count: n)
        let nameLength = try reader.array(UInt16.self, count: n)
        let names = try reader.array(UInt8.self, count: header.namesCount)
        let linkRecords = try reader.array(LinkRecord.self, count: header.linkGroupCount)
        let occurrenceRecords = try reader.array(OccurrenceRecord.self, count: header.occurrenceCount)
        guard reader.offset == data.count else { throw ScanCacheError("trailing bytes") }

        try validate(parent: parent, firstChild: firstChild, childCount: childCount, childOrder: childOrder,
                     nameOffset: nameOffset, nameLength: nameLength, namesCount: names.count)
        let groups = try linkRecords.map { record throws(ScanCacheError) in
            let first = Int(record.firstOccurrence), count = Int(record.occurrenceCount)
            guard first + count <= occurrenceRecords.count else { throw ScanCacheError("link occurrences exceed table") }
            let code = Int(record.flags >> 2 & 3)
            guard code < provenanceByCode.count else { throw ScanCacheError("link provenance") }
            var occurrences: [LinkOccurrence] = []
            for o in occurrenceRecords[first ..< first + count] {
                guard o.node >= 0, Int(o.node) < n else { throw ScanCacheError("link occurrence node") }
                occurrences.append(LinkOccurrence(node: o.node, depth: o.depth, isFolded: o.folded != 0))
            }
            return HardLinkGroup(
                identity: FileIdentity(dev: record.dev, ino: record.ino, isDirectory: record.flags & 1 != 0),
                linkCount: record.linkCount, allocBytes: record.allocBytes,
                privateBytes: record.flags & 2 != 0 ? record.privateBytes : nil,
                provenance: provenanceByCode[code], occurrences: occurrences
            )
        }
        return StorageTree(
            root: header.root, volumeUUID: header.volumeUUID, dev: header.dev,
            scanDate: Date(timeIntervalSinceReferenceDate: Double(bitPattern: header.scanDateBits)),
            lastEventId: header.lastEventId, parent: parent, firstChild: firstChild, childCount: childCount,
            allocBytes: allocBytes, smallBytes: smallBytes, smallCount: smallCount, fileID: fileID, mtime: mtime,
            subtreeMaxMtime: subtreeMaxMtime, addedTime: addedTime, flags: flags.map(StorageNodeFlags.init),
            markerMask: markers.map(StorageMarker.init), nameOffset: nameOffset, nameLength: nameLength, names: names,
            childOrder: childOrder, childPrefix: childPrefix, linkGroups: groups
        )
    }

    /// The invariants every `StorageTree` reader relies on (`parent < child`, contiguous child ranges, names
    /// inside the pool): a corrupt file must fail here, not as an out-of-range index later.
    private static func validate(parent: [Int32], firstChild: [Int32], childCount: [Int32], childOrder: [Int32],
                                 nameOffset: [UInt32], nameLength: [UInt16], namesCount: Int) throws(ScanCacheError) {
        let n = parent.count
        for i in 0 ..< n {
            guard Int(nameOffset[i]) + Int(nameLength[i]) <= namesCount else { throw ScanCacheError("name out of pool") }
            let count = Int(childCount[i])
            if count > 0 {
                let start = Int(firstChild[i])
                guard start > i, start + count <= n else { throw ScanCacheError("child range of node \(i)") }
                for k in start ..< start + count {
                    guard Int(parent[k]) == i else { throw ScanCacheError("child \(k) not owned by \(i)") }
                    let ordered = Int(childOrder[k])
                    guard ordered >= start, ordered < start + count else { throw ScanCacheError("child order of \(i)") }
                }
            } else if count < 0 {
                throw ScanCacheError("negative child count")
            }
            if i > 0 { guard parent[i] >= 0, Int(parent[i]) < i else { throw ScanCacheError("parent of \(i)") } }
        }
    }
}
