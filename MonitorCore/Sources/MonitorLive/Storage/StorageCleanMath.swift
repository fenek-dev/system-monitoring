import Foundation
import MonitorModel
import os

/// Overlay mutation for clean/undo outcomes and the "reclaimable" total. One implementation shared by
/// `StorageModel` (live page) and `StoragePipeline` (persisted overlay + summary file), so the two never disagree.
public enum StorageCleanMath {
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    /// A skipped item changes nothing. Otherwise the overlay follows what the cleaner did to the item's mode.
    public static func apply(_ outcome: CleanItemOutcome, item: CleanupItem, to overlay: inout StorageTreeOverlay,
                             tree: StorageTree) throws(StorageOverlayError) {
        guard outcome.skip == nil else { return }
        switch item.mode {
        case .trash:
            if let node = item.nodeID { try overlay.remove(node, kind: .trashed, in: tree) }
        case .remove where item.keepParent:
            var removedBytes: UInt64 = 0
            for node in outcome.removedNodes {
                removedBytes += try overlay.size(node, in: tree) ?? 0
                try overlay.remove(node, kind: .deleted, in: tree)
            }
            // Children folded into the parent's small-file totals have no node; their bytes leave via the parent.
            if let node = item.nodeID, outcome.detachedBytes > removedBytes {
                try overlay.shrink(node, by: outcome.detachedBytes - removedBytes, in: tree)
            }
        case .remove:
            if let node = item.nodeID { try overlay.remove(node, kind: .deleted, in: tree) }
        case .evict:
            // The placeholder stays; only its local bytes go.
            if let node = item.nodeID { try overlay.shrink(node, by: outcome.detachedBytes, in: tree) }
        case .simctl, .none:
            break
        }
    }

    /// Undo of a trashed item. A vanished original parent leaves the overlay unchanged (logged): there is no
    /// place in the tree to show the entry.
    public static func applyRestore(itemID: Int32, finalPath: String, item: CleanupItem,
                                    to overlay: inout StorageTreeOverlay,
                                    tree: StorageTree) throws(StorageOverlayError) {
        let parent: StorageNodeID?
        if let node = item.nodeID {
            parent = tree.parent[Int(node)]
        } else {
            parent = tree.lookup(path: (item.path as NSString).deletingLastPathComponent)
        }
        guard let parent else {
            log.error("restore of item \(itemID, privacy: .public): original parent not in tree, overlay unchanged")
            return
        }
        let entry = RestoredEntry(parent: parent, name: (finalPath as NSString).lastPathComponent,
                                  bytes: item.allocBytes, itemID: itemID)
        try overlay.restore(entry, originalNode: item.nodeID, in: tree)
    }

    /// Bytes a "clean everything eligible" would free. Trash is reported separately (`CleanupSet.trashBytes`),
    /// ignored and info-only items never count.
    public static func reclaimable(set: CleanupSet, tree: StorageTree,
                                   overlay: StorageTreeOverlay?) throws(StorageOverlayError)
        -> (bytes: UInt64, provenance: SizeProvenance) {
        let eligible = set.items.filter { !$0.ignored && $0.mode != .none && $0.category != .trash }
        var acc = try ReclaimAccumulator(items: eligible, tree: tree, overlay: overlay, linkSizes: set.linkGroupSizes)
        for item in eligible { acc.insert(item.id) }
        return (acc.bytes, acc.provenance)
    }
}
