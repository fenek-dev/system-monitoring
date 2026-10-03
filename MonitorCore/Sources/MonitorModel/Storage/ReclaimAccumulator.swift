import Foundation

/// Bytes freed by deleting a selection, with hard links counted over the selection's union: a link group's bytes
/// count only once every link of the file (its full `linkCount`) is covered by selected items. Counting per item
/// would either double-count a file whose links sit in two selected items or never count it.
///
/// Items without private sizes yet (`privateBytesExcludingLinks == nil`) contribute `allocBytes`, which already holds
/// the tree's once-credited link bytes, and take no part in link-group coverage (an estimate either way).
public struct ReclaimAccumulator: Sendable {
    private struct Entry: Sendable {
        var base: UInt64
        var provenance: SizeProvenance
        /// Link occurrences inside the item as (group index, occurrence index).
        var covers: [(group: Int32, occurrence: Int32)]
    }

    private let entries: [Int32: Entry]
    private let groupBytes: [Int32: (bytes: UInt64, linkCount: Int)]
    private var selected: Set<Int32> = []
    private var baseTotal: UInt64 = 0
    private var linkTotal: UInt64 = 0
    /// How many selected items cover each (group, occurrence).
    private var coverCount: [Int64: Int] = [:]
    /// Covered occurrences per group.
    private var coveredPerGroup: [Int32: Int] = [:]
    private var provenanceCounts: [SizeProvenance: Int] = [:]

    public init(items: [CleanupItem], tree: StorageTree) {
        var entries: [Int32: Entry] = [:]
        var groupBytes: [Int32: (bytes: UInt64, linkCount: Int)] = [:]
        for item in items {
            var covers: [(group: Int32, occurrence: Int32)] = []
            if item.privateBytesExcludingLinks != nil, let node = item.nodeID {
                for g in item.linkGroupIndices where g >= 0 && Int(g) < tree.linkGroups.count {
                    let group = tree.linkGroups[Int(g)]
                    groupBytes[g] = (group.bytes, Int(group.linkCount))
                    for (k, occ) in group.occurrences.enumerated()
                    where occ == node || tree.isAncestor(node, of: occ) {
                        covers.append((g, Int32(k)))
                    }
                }
            }
            entries[item.id] = Entry(base: item.privateBytesExcludingLinks ?? item.allocBytes,
                                     provenance: item.sizeProvenance, covers: covers)
        }
        self.entries = entries
        self.groupBytes = groupBytes
    }

    public var selectedIDs: Set<Int32> { selected }
    public var count: Int { selected.count }

    /// O(item's link occurrences). Unknown or already selected ids are ignored.
    public mutating func insert(_ id: Int32) {
        guard let entry = entries[id], selected.insert(id).inserted else { return }
        baseTotal = baseTotal.addingSaturating(entry.base)
        provenanceCounts[entry.provenance, default: 0] += 1
        for cover in entry.covers {
            let key = Self.key(cover.group, cover.occurrence)
            coverCount[key, default: 0] += 1
            guard coverCount[key] == 1 else { continue }
            coveredPerGroup[cover.group, default: 0] += 1
            if let g = groupBytes[cover.group], coveredPerGroup[cover.group] == g.linkCount {
                linkTotal = linkTotal.addingSaturating(g.bytes)
            }
        }
    }

    public mutating func remove(_ id: Int32) {
        guard let entry = entries[id], selected.remove(id) != nil else { return }
        baseTotal = baseTotal.subtractingSaturating(entry.base)
        provenanceCounts[entry.provenance, default: 1] -= 1
        for cover in entry.covers {
            let key = Self.key(cover.group, cover.occurrence)
            coverCount[key, default: 1] -= 1
            guard coverCount[key] == 0 else { continue }
            coverCount[key] = nil
            if let g = groupBytes[cover.group], coveredPerGroup[cover.group] == g.linkCount {
                linkTotal = linkTotal.subtractingSaturating(g.bytes)
            }
            coveredPerGroup[cover.group, default: 1] -= 1
        }
    }

    public var bytes: UInt64 { baseTotal.addingSaturating(linkTotal) }

    /// Worst provenance among selected items; `.exact` for an empty selection.
    public var provenance: SizeProvenance {
        provenanceCounts.filter { $0.value > 0 }.keys.max() ?? .exact
    }

    private static func key(_ group: Int32, _ occurrence: Int32) -> Int64 {
        Int64(group) << 32 | Int64(UInt32(bitPattern: occurrence))
    }
}

private extension UInt64 {
    func addingSaturating(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }

    func subtractingSaturating(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
