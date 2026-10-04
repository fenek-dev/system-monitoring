import Darwin
import Foundation
import MonitorModel

public struct ScanCacheError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// On-disk copy of the last complete scan per (volume, root) so the app opens with a tree instead of a rescan.
///
/// File `storage-scan-<fnv1a64(uuid + kind + root path)>.bin`: magic, schema, JSON header (identity, counts), then
/// the tree's *primary* data as raw little-endian sections: structure (parent per node), per-node own bytes, flags,
/// ids, times, names, markers, and the hard-link groups with their occurrences. Nothing derived is stored. On load
/// the tree is rebuilt through `StorageTreeBuilder`, the same path a scan takes, so rollups, link credits, child
/// order and prefix sums are recomputed and can never disagree with each other; the only checks left are range and
/// size checks on the primary data (including that no byte sum can overflow). Anything off deletes the file and
/// reads as a miss. Written to a temp file and renamed into place; read through a memory map.
///
/// The overlay is persisted as its mutation log (`<same name>.overlay.json`) and replayed through the public
/// overlay API on load, so an overlay's internal state is never decoded from disk.
public final class ScanCache: Sendable {
    /// Bump when the layout changes: older files read as a miss. 2: primary data only, derived data recomputed.
    public static let schema: UInt32 = 2

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

    private struct Sidecar: Codable {
        var scan: StorageTreeOverlay.ScanIdentity
        var log: [StorageTreeOverlay.Mutation]
    }

    public func saveOverlay(_ overlay: StorageTreeOverlay) throws(ScanCacheError) {
        let url = overlayURL(for: treeURL(root: overlay.scan.root, volumeUUID: overlay.scan.volumeUUID))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Sidecar(scan: overlay.scan, log: overlay.log)).write(to: url, options: .atomic)
        } catch {
            throw ScanCacheError("write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The cached tree with its overlay (the saved mutations replayed on it; a fresh one when there is none or it
    /// does not fit), or nil if there is no valid cache for this root and volume.
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
            let sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
            guard sidecar.scan == StorageTreeOverlay.ScanIdentity(tree) else { throw StorageOverlayError.treeMismatch }
            return try StorageTreeOverlay.replaying(sidecar.log, onto: tree)
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
        /// Bit pattern of `scanDate.timeIntervalSinceReferenceDate`: sidecar identity compares dates for equality.
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
        let n = tree.nodeCount
        // A node's stored size is its own: the tree's size includes the group credit that `finalize` adds at each
        // group's first occurrence, and the rebuild adds it again, so it is taken out here.
        var credit = [UInt64](repeating: 0, count: n)
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
            if let first = group.occurrences.first {
                credit[Int(first.node)] = try checkedSum(credit[Int(first.node)], group.allocBytes)
            }
        }
        var own = [UInt64](repeating: 0, count: n)
        for i in 0 ..< n where !tree.flags[i].contains(.restricted) {
            let held = tree.flags[i].contains(.directory) ? tree.smallBytes[i] : tree.allocBytes[i]
            let (rest, underflow) = held.subtractingReportingOverflow(credit[i])
            guard !underflow else { throw ScanCacheError("node \(i) holds less than its link credit") }
            own[i] = rest
        }
        let header = Header(
            root: tree.root, volumeUUID: tree.volumeUUID, dev: tree.dev,
            scanDateBits: tree.scanDate.timeIntervalSinceReferenceDate.bitPattern, lastEventId: tree.lastEventId,
            nodeCount: n, namesCount: tree.names.count, linkGroupCount: records.count,
            occurrenceCount: occurrences.count
        )
        let headerJSON: Data
        do {
            headerJSON = try JSONEncoder().encode(header)
        } catch {
            throw ScanCacheError("header: \(error)")
        }

        var out = Data()
        out.reserveCapacity(prefixLength + headerJSON.count + n * 80 + tree.names.count)
        out.append(contentsOf: magic)
        append(UInt32(schema), to: &out)
        append(UInt32(headerJSON.count), to: &out)
        out.append(headerJSON)
        pad(&out)
        // Wider elements first; every section stays 8-byte aligned.
        section(own, &out); section(tree.fileID, &out); section(tree.mtime, &out); section(tree.addedTime, &out)
        section(tree.subtreeMaxMtime, &out)
        section(tree.parent, &out); section(tree.smallCount, &out); section(tree.markerMask.map(\.rawValue), &out)
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

    private static func checkedSum(_ a: UInt64, _ b: UInt64) throws(ScanCacheError) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw ScanCacheError("byte sum overflows") }
        return sum
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
        // Every node costs well over 32 bytes in the file: a count the file cannot hold is rejected before any
        // allocation sized by it.
        guard n > 0, n <= Int(Int32.max), n <= data.count / 32, header.namesCount >= 0, header.namesCount <= data.count,
              header.linkGroupCount >= 0, header.occurrenceCount >= 0 else {
            throw ScanCacheError("implausible counts")
        }

        var reader = Reader(data: data, offset: (prefixLength + headerLength + 7) / 8 * 8)
        let own = try reader.array(UInt64.self, count: n)
        let fileID = try reader.array(UInt64.self, count: n)
        let mtime = try reader.array(Int64.self, count: n)
        let addedTime = try reader.array(Int64.self, count: n)
        let subtreeMaxMtime = try reader.array(Int64.self, count: n)
        let parent = try reader.array(Int32.self, count: n)
        let smallCount = try reader.array(UInt32.self, count: n)
        let markers = try reader.array(UInt32.self, count: n)
        let flags = try reader.array(UInt16.self, count: n)
        let nameLength = try reader.array(UInt16.self, count: n)
        let names = try reader.array(UInt8.self, count: header.namesCount)
        let linkRecords = try reader.array(LinkRecord.self, count: header.linkGroupCount)
        let occurrenceRecords = try reader.array(OccurrenceRecord.self, count: header.occurrenceCount)
        guard reader.offset == data.count else { throw ScanCacheError("trailing bytes") }

        // Structure: every parent precedes its children, and each parent's children are one run of consecutive ids
        // (the shape a scan produces); that is all the builder needs, and all it will be given.
        guard parent[0] == 0 else { throw ScanCacheError("root parent") }
        var runs: [(parent: Int32, range: Range<Int>)] = []
        var hasRun = [Bool](repeating: false, count: n)
        var i = 1
        while i < n {
            let p = parent[i]
            guard p >= 0, Int(p) < i, !hasRun[Int(p)] else { throw ScanCacheError("parent of node \(i)") }
            hasRun[Int(p)] = true
            var j = i
            while j < n, parent[j] == p { j += 1 }
            runs.append((p, i ..< j))
            i = j
        }
        // Names: the lengths must tile the pool exactly.
        var nameStart = [Int](repeating: 0, count: n)
        var cursor = 0
        for k in 0 ..< n {
            nameStart[k] = cursor
            cursor += Int(nameLength[k])
        }
        guard cursor == names.count else { throw ScanCacheError("names do not tile the pool") }
        // Sizes: every rolled-up value is a partial sum of the own bytes and group sizes, so if their total fits no
        // addition in the rebuild can overflow.
        var total: UInt64 = 0
        for value in own { total = try checkedSum(total, value) }
        for record in linkRecords { total = try checkedSum(total, record.allocBytes) }
        for record in linkRecords {
            let first = Int(record.firstOccurrence), count = Int(record.occurrenceCount)
            guard first + count <= occurrenceRecords.count else { throw ScanCacheError("link occurrences exceed table") }
            guard Int(record.flags >> 2 & 3) < provenanceByCode.count else { throw ScanCacheError("link provenance") }
        }
        for occurrence in occurrenceRecords where occurrence.node < 0 || Int(occurrence.node) >= n {
            throw ScanCacheError("link occurrence node")
        }

        var builder = StorageTreeBuilder(root: header.root, dev: header.dev, volumeUUID: header.volumeUUID,
                                         rootFileID: fileID[0], rootMtime: mtime[0])
        for run in runs {
            let children = run.range.map { k in
                let nodeFlags = StorageNodeFlags(rawValue: flags[k])
                return NodeRecord(name: Array(names[nameStart[k] ..< nameStart[k] + Int(nameLength[k])]),
                                  flags: nodeFlags, allocBytes: nodeFlags.contains(.directory) ? 0 : own[k],
                                  fileID: fileID[k], mtime: mtime[k], addedTime: addedTime[k])
            }
            builder.appendChildren(of: run.parent, children)
        }
        for k in 0 ..< n {
            let nodeFlags = StorageNodeFlags(rawValue: flags[k])
            if nodeFlags.contains(.directory), own[k] > 0 || smallCount[k] > 0 || subtreeMaxMtime[k] > mtime[k] {
                // Folded small files: bytes, count, and the newest mtime in this subtree (the one input of
                // `subtreeMaxMtime` that is not recoverable from other nodes).
                builder.addSmall(Int32(k), bytes: own[k], count: smallCount[k], maxMtime: subtreeMaxMtime[k])
            }
            let extra = k == 0 ? nodeFlags.subtracting(.directory) : []
            if markers[k] != 0 || !extra.isEmpty {
                builder.setDirFacts(Int32(k), markers: StorageMarker(rawValue: markers[k]), flags: extra)
            }
        }
        for record in linkRecords {
            let identity = FileIdentity(dev: record.dev, ino: record.ino, isDirectory: record.flags & 1 != 0)
            let first = Int(record.firstOccurrence)
            for occurrence in occurrenceRecords[first ..< first + Int(record.occurrenceCount)] {
                builder.addLink(identity, linkCount: record.linkCount, bytes: record.allocBytes,
                                occurrence: occurrence.node,
                                privateBytes: record.flags & 2 != 0 ? record.privateBytes : nil,
                                depth: occurrence.depth)
            }
        }
        return builder.finalize(
            scanDate: Date(timeIntervalSinceReferenceDate: Double(bitPattern: header.scanDateBits)),
            lastEventId: header.lastEventId)
    }
}
