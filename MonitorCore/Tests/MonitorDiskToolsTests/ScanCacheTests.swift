import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct ScanCacheTests {
    private static let uuid = UUID(uuidString: "6F1C2A52-0000-4000-8000-00000000ABCD")!
    private static let otherUUID = UUID(uuidString: "6F1C2A52-0000-4000-8000-00000000DCBA")!
    /// Fractional seconds: rebasing an overlay compares scan dates for exact equality.
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

    /// Bug: a wrong or torn cache is loaded (any array lost or reordered, scan date rounded, overlay unbound).
    @Test func roundTripsTreeAndOverlay() throws {
        let cache = ScanCache(directory: try tempDirectory())
        let tree = sampleTree()
        try cache.save(tree)
        var overlay = StorageTreeOverlay(tree: tree)
        let caches = try #require(tree.lookup(path: "/Users/test/Library/Caches"))
        try overlay.remove(caches, kind: .deleted, in: tree)
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
        #expect(try loaded.overlay.size(0, in: t) == t.allocBytes[0] - tree.allocBytes[Int(caches)])
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
        case otherVolumeInHeader, schemaPlusOne, truncatedMidArray, truncatedInHeader, flippedParent, garbageMagic
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
        case .flippedParent:
            // The last node's parent index pointing past itself would index out of range in every tree reader.
            bytes = Self.corruptParent(of: bytes, tree: tree, node: tree.nodeCount - 1)
        case .garbageMagic:
            bytes[0] = 0
        }
        try Data(bytes).write(to: url)
        #expect(cache.load(root: tree.root, volumeUUID: Self.uuid) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Overwrites `parent[node]` in the encoded file: the parent section follows the seven 8-byte arrays.
    private static func corruptParent(of bytes: [UInt8], tree: StorageTree, node: Int) -> [UInt8] {
        var out = bytes
        let headerLength = Int(out[12]) | Int(out[13]) << 8 | Int(out[14]) << 16 | Int(out[15]) << 24
        let sectionsStart = (16 + headerLength + 7) / 8 * 8
        let parentStart = sectionsStart + 7 * tree.nodeCount * 8
        let at = parentStart + node * 4
        let bad = UInt32(node + 5).littleEndian
        withUnsafeBytes(of: bad) { for (i, b) in $0.enumerated() { out[at + i] = b } }
        return out
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
