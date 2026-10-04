import Foundation

/// Bytes freed by deleting a selection, with hard links counted over the selection's union: a group's bytes count
/// once, and only when the selection covers every link the file still has — `linkCount` (all filesystem links,
/// including those outside the scan) minus links already deleted (overlay). A trashed link still pins the blocks.
/// Counting per item would double-count a file linked from two selected items, or never count it.
///
/// Group bytes: private bytes when exact, else allocated bytes with `.estimate` provenance. Items without private
/// sizes yet (`privateBytesExcludingLinks == nil`) contribute `allocBytes`, which already holds the tree's
/// once-credited link bytes, and take no part in link coverage (an estimate either way).
/// Totals are kept in 128 bits, so deselecting after a sum past `UInt64.max` stays exact; reads clamp.
public struct ReclaimAccumulator: Sendable {
    private struct Entry: Sendable {
        var base: UInt64
        var provenance: SizeProvenance
        /// Surviving link occurrences inside the item, as (group index, occurrence index).
        var covers: [(group: Int32, occurrence: Int32)]
    }

    private struct Group: Sendable {
        var bytes: UInt64
        var provenance: SizeProvenance
        /// Links the file still has anywhere.
        var required: Int
    }

    private let entries: [Int32: Entry]
    private let groups: [Int32: Group]
    private var selected: Set<Int32> = []
    private var total: UInt128 = 0
    /// How many selected items cover each (group, occurrence).
    private var coverCount: [Int64: Int] = [:]
    /// Covered occurrences per group.
    private var coveredPerGroup: [Int32: Int] = [:]
    private var provenanceCounts: [SizeProvenance: Int] = [:]

    /// `overlay`: removals so far (deleted links lower the required count; removed occurrences can't be covered).
    /// `linkSizes`: private sizes from the private-size pass (`CleanupSet.linkGroupSizes`), overriding the tree's.
    public init(items: [CleanupItem], tree: StorageTree, overlay: StorageTreeOverlay? = nil,
                linkSizes: [Int32: LinkGroupSize] = [:]) throws(StorageOverlayError) {
        if let overlay, overlay.treeVersion != tree.version { throw .treeMismatch }
        var entries: [Int32: Entry] = [:]
        var groups: [Int32: Group] = [:]
        for item in items {
            var covers: [(group: Int32, occurrence: Int32)] = []
            if item.privateBytesExcludingLinks != nil, let node = item.nodeID {
                for g in item.linkGroupIndices where g >= 0 && Int(g) < tree.linkGroups.count {
                    let group = tree.linkGroups[Int(g)]
                    if groups[g] == nil {
                        let size = linkSizes[g] ?? LinkGroupSize(privateBytes: group.privateBytes,
                                                                 provenance: group.provenance)
                        let deleted = overlay?.deletedLinkCount(group: g) ?? 0
                        groups[g] = if size.provenance == .exact, let p = size.privateBytes {
                            Group(bytes: p, provenance: .exact, required: Int(group.linkCount) - deleted)
                        } else {
                            Group(bytes: group.allocBytes, provenance: max(size.provenance, .estimate),
                                  required: Int(group.linkCount) - deleted)
                        }
                    }
                    for (k, occ) in group.occurrences.enumerated()
                    where (occ.node == node || tree.isAncestor(node, of: occ.node))
                        && overlay?.linkSurvives(group: g, occurrence: Int32(k)) ?? true {
                        covers.append((g, Int32(k)))
                    }
                }
            }
            entries[item.id] = Entry(base: item.privateBytesExcludingLinks ?? item.allocBytes,
                                     provenance: item.sizeProvenance, covers: covers)
        }
        self.entries = entries
        self.groups = groups
    }

    public var selectedIDs: Set<Int32> { selected }
    public var count: Int { selected.count }

    /// O(item's link occurrences). Unknown or already selected ids are ignored.
    public mutating func insert(_ id: Int32) {
        guard let entry = entries[id], selected.insert(id).inserted else { return }
        total += UInt128(entry.base)
        provenanceCounts[entry.provenance, default: 0] += 1
        for cover in entry.covers {
            let key = Self.key(cover.group, cover.occurrence)
            coverCount[key, default: 0] += 1
            guard coverCount[key] == 1, let g = groups[cover.group] else { continue }
            coveredPerGroup[cover.group, default: 0] += 1
            if coveredPerGroup[cover.group] == g.required {
                total += UInt128(g.bytes)
                provenanceCounts[g.provenance, default: 0] += 1
            }
        }
    }

    public mutating func remove(_ id: Int32) {
        guard let entry = entries[id], selected.remove(id) != nil else { return }
        total -= UInt128(entry.base)
        provenanceCounts[entry.provenance, default: 1] -= 1
        for cover in entry.covers {
            let key = Self.key(cover.group, cover.occurrence)
            coverCount[key, default: 1] -= 1
            guard coverCount[key] == 0, let g = groups[cover.group] else { continue }
            coverCount[key] = nil
            if coveredPerGroup[cover.group] == g.required {
                total -= UInt128(g.bytes)
                provenanceCounts[g.provenance, default: 1] -= 1
            }
            coveredPerGroup[cover.group, default: 1] -= 1
        }
    }

    /// Clamped to `UInt64.max`.
    public var bytes: UInt64 { UInt64(clamping: total) }

    /// Worst provenance among selected items and counted link groups; `.exact` for an empty selection.
    public var provenance: SizeProvenance {
        provenanceCounts.filter { $0.value > 0 }.keys.max() ?? .exact
    }

    private static func key(_ group: Int32, _ occurrence: Int32) -> Int64 {
        Int64(group) << 32 | Int64(UInt32(bitPattern: occurrence))
    }
}
