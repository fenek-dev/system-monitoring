import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct ScanCacheTests {
    private static let uuid = UUID(uuidString: "6F1C2A52-0000-4000-8000-00000000ABCD")!
    private static let otherUUID = UUID(uuidString: "6F1C2A52-0000-4000-8000-00000000DCBA")!
    /// Fractional seconds: the sidecar's scan identity compares dates for exact equality.
    private static let scanDate = Date(timeIntervalSinceReferenceDate: 780_000_000.123_456_789)

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scancache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A tree with every optional feature: kept and folded hard links (one with private bytes), a restricted dir,
    /// a package, markers, non-ASCII names.
    private func sampleTree(uuid: UUID? = uuid) -> StorageTree {
        let base = TreeFixture.build([
            TreeFixture.dir("Library", markers: [.git, .podfile], mtime: 5, [
                TreeFixture.dir("Caches", flags: .hidden, [
                    TreeFixture.file("blob", 4_000_000, mtime: 9, added: 3),
                    TreeFixture.small(bytes: 300, count: 3, maxMtime: 7),
                ]),
                TreeFixture.link("a", ino: 7, linkCount: 3, bytes: 2_000_000),
                TreeFixture.link(nil, ino: 7, linkCount: 3, bytes: 2_000_000),
            ]),
            TreeFixture.dir("Foo.app", flags: .package, [TreeFixture.file("exe", 1_000_000)]),
            .restricted("locked"),
            TreeFixture.file("日本語.bin", 1_500_000),
        ])
        var groups = base.linkGroups
        groups[0].privateBytes = 777
        groups[0].provenance = .exact
        return StorageTree(
            root: base.root, volumeUUID: uuid, dev: base.dev, scanDate: Self.scanDate, lastEventId: 0xFEED_0000_0042,
            parent: base.parent, firstChild: base.firstChild, childCount: base.childCount, allocBytes: base.allocBytes,
            smallBytes: base.smallBytes, smallCount: base.smallCount, fileID: base.fileID, mtime: base.mtime,
            subtreeMaxMtime: base.subtreeMaxMtime, addedTime: base.addedTime, flags: base.flags,
            markerMask: base.markerMask, nameOffset: base.nameOffset, nameLength: base.nameLength, names: base.names,
            childOrder: base.childOrder, childPrefix: base.childPrefix, linkGroups: groups
        )
    }

    /// Bug: a wrong or torn cache is loaded: any array lost or reordered after the recompute (sizes, link credits,
    /// child order, prefix sums), scan date rounded, mutations of the overlay not replayed.
    @Test func roundTripsTreeAndOverlay() throws {
        let cache = ScanCache(directory: try tempDirectory())
        let tree = sampleTree()
        try cache.save(tree)
        var overlay = StorageTreeOverlay(tree: tree)
        let caches = try #require(tree.lookup(path: "/Users/test/Library/Caches"))
        try overlay.remove(caches, kind: .deleted, in: tree)
        try overlay.shrink(try #require(tree.lookup(path: "/Users/test/Foo.app")), by: 10, in: tree)
        try cache.saveOverlay(overlay)

        let loaded = try #require(cache.load(root: tree.root, volumeUUID: Self.uuid))
        let t = loaded.tree
        #expect(t.version != tree.version)
        #expect(t.root == tree.root && t.volumeUUID == tree.volumeUUID && t.dev == tree.dev)
        #expect(t.scanDate == tree.scanDate && t.lastEventId == tree.lastEventId)
        #expect(t.parent == tree.parent && t.firstChild == tree.firstChild && t.childCount == tree.childCount)
        #expect(t.allocBytes == tree.allocBytes && t.smallBytes == tree.smallBytes && t.smallCount == tree.smallCount)
        #expect(t.fileID == tree.fileID && t.mtime == tree.mtime && t.subtreeMaxMtime == tree.subtreeMaxMtime)
        #expect(t.addedTime == tree.addedTime && t.flags == tree.flags && t.markerMask == tree.markerMask)
        #expect(t.nameOffset == tree.nameOffset && t.nameLength == tree.nameLength && t.names == tree.names)
        #expect(t.childOrder == tree.childOrder && t.childPrefix == tree.childPrefix)
        #expect(t.linkGroups == tree.linkGroups)
        #expect(t.linkGroups.first?.privateBytes == 777)
        #expect(try loaded.overlay.isRemoved(caches, in: t))
        #expect(try loaded.overlay.size(0, in: t) == overlay.size(0, in: tree))
        #expect(loaded.overlay.log == overlay.log)
    }

    /// Bug: a rescan leaves the previous scan's overlay behind, hiding nodes of the new tree.
    @Test func savingANewTreeDropsTheOldOverlay() throws {
        let cache = ScanCache(directory: try tempDirectory())
        let tree = sampleTree()
        try cache.save(tree)
        var overlay = StorageTreeOverlay(tree: tree)
        try overlay.remove(try #require(tree.lookup(path: "/Users/test/Foo.app")), kind: .deleted, in: tree)
        try cache.saveOverlay(overlay)
        try cache.save(sampleTree())
        let loaded = try #require(cache.load(root: tree.root, volumeUUID: Self.uuid))
        #expect(loaded.overlay == StorageTreeOverlay(tree: loaded.tree))
    }

    enum Corruption: CaseIterable {
        case otherVolumeInHeader, schemaPlusOne, truncatedMidArray, truncatedInHeader, garbageMagic
        case inflatedNodeCount, parentPastItself, splitChildRun, ownBytesOverflow, linkGroupBytesOverflow
        case nameLengthsDoNotTile, linkOccurrenceOutOfRange
    }

    /// Bug: a cache that belongs elsewhere, predates a layout change, or is torn/corrupt is trusted (or crashes the
    /// reader); it must read as a miss and be deleted so the next scan replaces it.
    @Test(arguments: Corruption.allCases)
    func invalidFilesAreMissesAndDeleted(_ corruption: Corruption) throws {
        let dir = try tempDirectory()
        let cache = ScanCache(directory: dir)
        let tree = sampleTree()
        try cache.save(tree)
        let url = cache.treeURL(root: tree.root, volumeUUID: Self.uuid)
        var bytes = [UInt8](try Data(contentsOf: url))
        let layout = Layout(tree)
        switch corruption {
        case .otherVolumeInHeader:
            // A file under this key whose header names another volume (hash collision / copied file).
            let other = sampleTree(uuid: Self.otherUUID)
            try cache.save(other)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: cache.treeURL(root: tree.root, volumeUUID: Self.otherUUID), to: url)
            bytes = [UInt8](try Data(contentsOf: url))
        case .schemaPlusOne:
            bytes[8] = UInt8(ScanCache.schema + 1)
        case .truncatedMidArray:
            bytes = Array(bytes.prefix(bytes.count / 2))
        case .truncatedInHeader:
            bytes = Array(bytes.prefix(20))
        case .garbageMagic:
            bytes[0] = 0
        case .inflatedNodeCount:
            let length = layout.headerLength(bytes)
            let header = String(decoding: bytes[16 ..< 16 + length], as: UTF8.self)
            let digits = "\(tree.nodeCount)"
            // Same digit count (the header length field stays valid), different value.
            let wrong = String(repeating: digits.allSatisfy { $0 == "9" } ? "8" : "9", count: digits.count)
            let bad = header.replacingOccurrences(of: "\"nodeCount\":\(digits)", with: "\"nodeCount\":\(wrong)")
            #expect(bad != header)
            bytes.replaceSubrange(16 ..< 16 + length, with: Array(bad.utf8))
        case .parentPastItself:
            layout.poke(&bytes, .parent, index: tree.nodeCount - 1, value: UInt64(tree.nodeCount + 4), bytes)
        case .splitChildRun:
            // The last node claims root as parent again: root's children would no longer be one run.
            layout.poke(&bytes, .parent, index: tree.nodeCount - 1, value: 0, bytes)
            layout.poke(&bytes, .parent, index: tree.nodeCount - 2, value: 1, bytes)
        case .ownBytesOverflow:
            layout.poke(&bytes, .own, index: 1, value: UInt64.max, bytes)
            layout.poke(&bytes, .own, index: 2, value: UInt64.max, bytes)
        case .linkGroupBytesOverflow:
            layout.pokeLink(&bytes, field: .groupBytes, value: UInt64.max)
        case .nameLengthsDoNotTile:
            layout.poke(&bytes, .nameLength, index: 0, value: 1 + UInt64(tree.nameLength[0]), bytes)
        case .linkOccurrenceOutOfRange:
            layout.pokeLink(&bytes, field: .firstOccurrenceNode, value: UInt64(tree.nodeCount + 9))
        }
        try Data(bytes).write(to: url)
        #expect(cache.load(root: tree.root, volumeUUID: Self.uuid) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Bug (reproduced crash): a stored link credit that disagrees with the node that holds it (credit 20 against
    /// 10 own bytes) used to trap in the overlay's size math. Nothing derived is stored now, so the tampered file
    /// rebuilds into a self-consistent tree and the overlay works on it.
    @Test func tamperedLinkCreditCannotMakeAnInconsistentTree() throws {
        let cache = ScanCache(directory: try tempDirectory())
        let tree = sampleTree()
        try cache.save(tree)
        let url = cache.treeURL(root: tree.root, volumeUUID: Self.uuid)
        var bytes = [UInt8](try Data(contentsOf: url))
        Layout(tree).pokeLink(&bytes, field: .groupBytes, value: 20)
        try Data(bytes).write(to: url)

        let loaded = try #require(cache.load(root: tree.root, volumeUUID: Self.uuid))
        var overlay = loaded.overlay
        try overlay.remove(try #require(loaded.tree.lookup(path: "/Users/test/Library")), kind: .deleted, in: loaded.tree)
        #expect(try overlay.size(0, in: loaded.tree) != nil)
        #expect(loaded.tree.linkGroups.first?.allocBytes == 20)
        #expect(loaded.tree.allocBytes[0] == (0 ..< loaded.tree.nodeCount).reduce(0) { sum, i in
            loaded.tree.parent[i] == 0 && i != 0 ? sum + loaded.tree.allocBytes[i] : sum
        })
    }

    /// Where each section of the encoded file starts (format v2: primary data only).
    struct Layout {
        enum Section: CaseIterable {
            case own, fileID, mtime, addedTime, subtreeMaxMtime, parent, smallCount, markerMask, flags, nameLength, names

            func width(_ tree: StorageTree) -> Int {
                switch self {
                case .own, .fileID, .mtime, .addedTime, .subtreeMaxMtime: 8
                case .parent, .smallCount, .markerMask: 4
                case .flags, .nameLength: 2
                case .names: 1
                }
            }
        }

        enum LinkField { case groupBytes, firstOccurrenceNode }

        let tree: StorageTree

        init(_ tree: StorageTree) { self.tree = tree }

        func headerLength(_ out: [UInt8]) -> Int {
            Int(out[12]) | Int(out[13]) << 8 | Int(out[14]) << 16 | Int(out[15]) << 24
        }

        private func sectionsStart(_ bytes: [UInt8]) -> Int { (16 + headerLength(bytes) + 7) / 8 * 8 }

        private func count(_ section: Section) -> Int { section == .names ? tree.names.count : tree.nodeCount }

        /// Offset of the first link record: after the names section.
        private func linkStart(_ bytes: [UInt8]) -> Int {
            var offset = sectionsStart(bytes)
            for s in Section.allCases { offset += (count(s) * s.width(tree) + 7) / 8 * 8 }
            return offset
        }

        /// Overwrites element `index` of `section`.
        func poke(_ bytes: inout [UInt8], _ section: Section, index: Int, value: UInt64, _ original: [UInt8]) {
            var offset = sectionsStart(original)
            for s in Section.allCases {
                if s == section { break }
                offset += (count(s) * s.width(tree) + 7) / 8 * 8
            }
            write(&bytes, at: offset + index * section.width(tree), width: section.width(tree), value: value)
        }

        /// Overwrites a field of link group 0 (one 40-byte record; occurrence records follow the group table).
        func pokeLink(_ bytes: inout [UInt8], field: LinkField, value: UInt64) {
            let start = linkStart(bytes)
            switch field {
            case .groupBytes: write(&bytes, at: start + 16, width: 8, value: value)
            case .firstOccurrenceNode:
                write(&bytes, at: start + tree.linkGroups.count * 40, width: 4, value: value)
            }
        }

        private func write(_ bytes: inout [UInt8], at: Int, width: Int, value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { for i in 0 ..< width { bytes[at + i] = $0[i] } }
        }
    }

    // MARK: Sidecar (mutation log)

    private func sidecarURL(_ cache: ScanCache, _ tree: StorageTree) -> URL {
        cache.treeURL(root: tree.root, volumeUUID: Self.uuid).deletingPathExtension().appendingPathExtension("overlay.json")
    }

    private func writeSidecar(_ url: URL, scan: StorageTreeOverlay.ScanIdentity, log: [StorageTreeOverlay.Mutation]) throws {
        struct Payload: Codable {
            var scan: StorageTreeOverlay.ScanIdentity
            var log: [StorageTreeOverlay.Mutation]
        }
        try JSONEncoder().encode(Payload(scan: scan, log: log)).write(to: url)
    }

    /// Bug: a sidecar that decodes fine but means something impossible for this tree (a node that does not exist,
    /// another scan's identity) is applied, or crashes the replay. Each payload is well-formed JSON of the real
    /// format; the load must discard it, delete it and hand back a fresh overlay, leaving the tree cache alone.
    @Test(arguments: ["removeOutsideTree", "shrinkOutsideTree", "restoreParentOutsideTree", "restoreOriginalOutsideTree",
                      "negativeNode", "otherScanIdentity"])
    func semanticallyWrongSidecarIsDiscarded(_ kind: String) throws {
        let cache = ScanCache(directory: try tempDirectory())
        let tree = sampleTree()
        try cache.save(tree)
        let outside = StorageNodeID(tree.nodeCount + 100)
        var scan = StorageTreeOverlay.ScanIdentity(tree)
        let log: [StorageTreeOverlay.Mutation]
        switch kind {
        case "removeOutsideTree": log = [.remove(outside, .deleted)]
        case "shrinkOutsideTree": log = [.shrink(outside, 5)]
        case "restoreParentOutsideTree": log = [.restore(RestoredEntry(parent: outside, name: "x", bytes: 5, itemID: 1), nil)]
        case "restoreOriginalOutsideTree": log = [.restore(RestoredEntry(parent: 0, name: "x", bytes: 5, itemID: 1), outside)]
        case "negativeNode": log = [.remove(-1, .trashed)]
        default:
            scan.nodeCount += 1
            log = [.remove(1, .deleted)]
        }
        let url = sidecarURL(cache, tree)
        try writeSidecar(url, scan: scan, log: log)

        let loaded = try #require(cache.load(root: tree.root, volumeUUID: Self.uuid))
        #expect(loaded.overlay == StorageTreeOverlay(tree: loaded.tree))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Bug (reproduced crash): a snapshot counter at `Int32.max` (decoded overlay state) trapped on the next trashed
    /// removal. The counter is checked now: the removal throws instead.
    @Test func snapshotCounterOverflowThrowsInsteadOfTrapping() throws {
        let tree = sampleTree()
        let overlay = StorageTreeOverlay(tree: tree)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(overlay)) as? [String: Any])
        json["nextSnapshot"] = Int(Int32.max)
        var decoded = try JSONDecoder().decode(StorageTreeOverlay.self, from: JSONSerialization.data(withJSONObject: json))
            .rebased(onto: tree)
        #expect(throws: StorageOverlayError.counterOverflow) {
            try decoded.remove(1, kind: .trashed, in: tree)
        }
        try decoded.remove(1, kind: .deleted, in: tree)
    }

    @Test func missingFileIsAMissWithoutSideEffects() throws {
        let cache = ScanCache(directory: try tempDirectory())
        #expect(cache.load(root: .home("/Users/nobody"), volumeUUID: nil) == nil)
    }

    /// Bug: caches of different roots or volumes share a file.
    @Test func differentRootsAndVolumesUseDifferentFiles() throws {
        let cache = ScanCache(directory: try tempDirectory())
        let tree = sampleTree()
        try cache.save(tree)
        #expect(cache.load(root: .folder("/Users/test"), volumeUUID: Self.uuid) == nil)
        #expect(cache.load(root: tree.root, volumeUUID: Self.otherUUID) == nil)
        #expect(cache.load(root: tree.root, volumeUUID: Self.uuid) != nil)
    }
}
