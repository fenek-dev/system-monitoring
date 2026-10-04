import Foundation
import os
import Testing
import MonitorModel
@testable import MonitorLive

/// Counters a `@Sendable` action closure can bump.
final class CallCounter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { lock.withLock { $0 } }
    func bump() { lock.withLock { $0 += 1 } }
}

/// Test-owned streams behind `StorageActions`: the test yields events, finishes the stream, then awaits the
/// model's task. No real disk, no sleeps.
@MainActor
final class StorageHarness {
    let cancelScan = CallCounter()
    let cancelClean = CallCounter()
    let release = CallCounter()
    let scans = CallCounter()
    var scanStream = AsyncStream<ScanEvent>.makeStream()
    var cleanStream = AsyncStream<CleanEvent>.makeStream()
    var undoStream = AsyncStream<CleanEvent>.makeStream()
    var reclassified: CleanupSet?

    func actions(loadCached: (@MainActor @Sendable (ScanRoot, ClassifyOptions) async
        -> (StorageTree, StorageTreeOverlay, CleanupSet)?)? = nil,
        summary: StorageSummary? = nil) -> StorageActions {
        let scan = scanStream
        let clean = cleanStream
        let undo = undoStream
        let (cancelScan, cancelClean, release, scans) = (self.cancelScan, self.cancelClean, self.release, self.scans)
        let reclassified = self.reclassified
        var a = StorageActions(
            scan: { _, _ in scans.bump(); return scan.stream },
            cancelScan: { cancelScan.bump() },
            loadSummary: { summary },
            reclassify: { _ in reclassified },
            clean: { _ in clean.stream },
            cancelClean: { cancelClean.bump() },
            undo: { _ in undo.stream },
            emptyTrash: { clean.stream },
            release: { release.bump() })
        if let loadCached { a.loadCached = loadCached }
        return a
    }
}

/// Scan tree used by the storage tests (root `/Users/t`):
/// A, B each hold one link of a 2-link file (group 0, private 100); C = c1 20 + c2 50 + 10 folded small bytes;
/// D 500; E 700; F/G/H/z 40 (a deep path for focus tests).
struct StorageFixture {
    let tree: StorageTree
    let a, b, c, c1, c2, d, e, f, g, h, trash, t1, t2: StorageNodeID

    static func file(_ name: String, _ bytes: UInt64) -> NodeRecord {
        NodeRecord(name: name, flags: [], allocBytes: bytes, fileID: 0, mtime: 0, addedTime: 0)
    }

    static func dir(_ name: String) -> NodeRecord {
        NodeRecord(name: name, flags: .directory, allocBytes: 0, fileID: 0, mtime: 0, addedTime: 0)
    }

    static func make() -> StorageFixture {
        var builder = StorageTreeBuilder(root: .home("/Users/t"), dev: 1, volumeUUID: nil)
        let top = builder.appendChildren(of: 0, ["A", "B", "C", "D", "E", "F", ".Trash"].map(dir))
        let (a, b, c, d, e, f, trash) = (top.lowerBound, top.lowerBound + 1, top.lowerBound + 2, top.lowerBound + 3,
                                         top.lowerBound + 4, top.lowerBound + 5, top.lowerBound + 6)
        let x = builder.appendChildren(of: a, [file("x", 0)]).lowerBound
        let y = builder.appendChildren(of: b, [file("y", 0)]).lowerBound
        let link = FileIdentity(dev: 1, ino: 10, isDirectory: false)
        builder.addLink(link, linkCount: 2, bytes: 4096, occurrence: x, privateBytes: 100)
        builder.addLink(link, linkCount: 2, bytes: 4096, occurrence: y, privateBytes: 100)
        let children = builder.appendChildren(of: c, [file("c1", 20), file("c2", 50)])
        builder.addSmall(c, bytes: 10, count: 1, maxMtime: 0)
        builder.appendChildren(of: d, [file("d", 500)])
        builder.appendChildren(of: e, [file("e", 700)])
        let g = builder.appendChildren(of: f, [dir("G")]).lowerBound
        let h = builder.appendChildren(of: g, [dir("H")]).lowerBound
        builder.appendChildren(of: h, [file("z", 40)])
        let trashed = builder.appendChildren(of: trash, [file("t1", 30), file("t2", 70)])
        let tree = builder.finalize(scanDate: Date(timeIntervalSince1970: 1_000), lastEventId: 0)
        return StorageFixture(tree: tree, a: a, b: b, c: c, c1: children.lowerBound, c2: children.lowerBound + 1,
                              d: d, e: e, f: f, g: g, h: h, trash: trash, t1: trashed.lowerBound,
                              t2: trashed.lowerBound + 1)
    }

    func item(_ id: Int32, node: StorageNodeID?, name: String? = nil, path: String? = nil,
              category: CleanupCategory = .userCaches, tier: SafetyTier = .safe, mode: DeleteMode = .remove,
              bytes: UInt64? = nil, privateBytes: UInt64? = nil, groups: [Int32] = [],
              owner: OwnerApp? = nil, keepParent: Bool = false, ignored: Bool = false,
              runningApp: Bool = false) -> CleanupItem {
        let name = name ?? node.map { tree.name($0) } ?? "item\(id)"
        return CleanupItem(
            id: id, nodeID: node, path: path ?? node.map { tree.path($0) } ?? "/Users/t/\(name)", name: name,
            category: category, tier: tier, mode: mode, identity: nil,
            allocBytes: bytes ?? node.flatMap { tree.size($0) } ?? 0, privateBytesExcludingLinks: privateBytes,
            linkGroupIndices: groups, sizeProvenance: privateBytes == nil ? .estimate : .exact, owner: owner,
            runningApp: runningApp, keepParent: keepParent, ignored: ignored)
    }

    func set(_ items: [CleanupItem], trashBytes: UInt64? = 0) -> CleanupSet {
        CleanupSet(treeVersion: tree.version, items: items, ownershipResolved: true, privateSizesFinal: true,
                   trashBytes: trashBytes)
    }
}

/// What the footer must show: a fresh accumulator over the current items and overlay with the same checked ids.
@MainActor
func expectedSelection(_ model: StorageModel) throws -> (bytes: UInt64, provenance: SizeProvenance, count: Int) {
    let tree = try #require(model.spaceMap.tree)
    var acc = try ReclaimAccumulator(items: model.cleanup.items, tree: tree, overlay: model.spaceMap.overlay)
    for id in model.cleanup.checked { acc.insert(id) }
    return (acc.bytes, acc.provenance, acc.count)
}
