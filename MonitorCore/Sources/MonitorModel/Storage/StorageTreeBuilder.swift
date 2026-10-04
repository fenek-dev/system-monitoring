import Foundation

/// Arena the scanner fills while walking; `finalize` turns it into an immutable `StorageTree`.
///
/// A node is allocated when its parent is listed, so `parent < child` always holds and a single reverse pass rolls
/// sizes up, whatever order the listings were committed in. A value type: the scanner keeps it in a `Mutex`.
public struct StorageTreeBuilder: Sendable {
    public let root: ScanRoot
    public let dev: Int32
    public let volumeUUID: UUID?

    private var parent: [Int32] = []
    private var firstChild: [Int32] = []
    private var childCount: [Int32] = []
    private var allocBytes: [UInt64] = []
    private var smallBytes: [UInt64] = []
    private var smallCount: [UInt32] = []
    private var fileID: [UInt64] = []
    private var mtime: [Int64] = []
    private var subtreeMaxMtime: [Int64] = []
    private var addedTime: [Int64] = []
    private var flags: [StorageNodeFlags] = []
    private var markerMask: [StorageMarker] = []
    private var nameOffset: [UInt32] = []
    private var nameLength: [UInt16] = []
    private var names: [UInt8] = []
    /// Occurrences are raw nodes here; depth, folding and order are settled in `build`.
    private var links: [(group: HardLinkGroup, nodes: [(node: StorageNodeID, depth: Int32?)])] = []
    private var linkIndex: [FileIdentity: Int] = [:]

    /// Creates the root node (id 0) as a directory named after the root path's last component.
    public init(root: ScanRoot, dev: Int32, volumeUUID: UUID?, rootFileID: UInt64 = 0, rootMtime: Int64 = 0) {
        self.root = root
        self.dev = dev
        self.volumeUUID = volumeUUID
        let last = root.path.split(separator: "/").last.map(String.init) ?? "/"
        append(NodeRecord(name: last, flags: .directory, allocBytes: 0, fileID: rootFileID, mtime: rootMtime,
                          addedTime: 0), parent: 0)
    }

    public var nodeCount: Int { parent.count }

    /// Appends a listing's children as one contiguous range. A directory's children must be committed in one call,
    /// or in consecutive calls with nothing appended in between (bounded batches of the same listing).
    @discardableResult
    public mutating func appendChildren(of node: StorageNodeID, _ records: [NodeRecord]) -> Range<Int32> {
        let p = Int(node)
        let start = Int32(nodeCount)
        if childCount[p] == 0 {
            firstChild[p] = start
        } else {
            precondition(firstChild[p] + childCount[p] == start, "children of node \(node) are not contiguous")
        }
        for record in records { append(record, parent: node) }
        childCount[p] += Int32(records.count)
        return start ..< Int32(nodeCount)
    }

    /// Facts known once a directory's own listing is done (markers among its entries, extra flags).
    public mutating func setDirFacts(_ node: StorageNodeID, markers: StorageMarker, flags extra: StorageNodeFlags) {
        markerMask[Int(node)].formUnion(markers)
        flags[Int(node)].formUnion(extra)
    }

    public mutating func setRestricted(_ node: StorageNodeID) {
        flags[Int(node)].insert(.restricted)
    }

    /// Folds small files into `dir`. Their newest mtime still feeds `subtreeMaxMtime`.
    public mutating func addSmall(_ dir: StorageNodeID, bytes: UInt64, count: UInt32, maxMtime: Int64) {
        let d = Int(dir)
        smallBytes[d] += bytes
        smallCount[d] += count
        subtreeMaxMtime[d] = max(subtreeMaxMtime[d], maxMtime)
    }

    /// Records one observed link of a hard-linked file; `occurrence` is its file node if kept, else the directory it
    /// was folded into (a directory occurrence counts as folded). The bytes are not part of any
    /// `NodeRecord.allocBytes` / `addSmall` bytes; `finalize` credits them once. `linkCount` keeps the largest value
    /// seen. `privateBytes`: `ATTR_CMNEXT_PRIVATESIZE` if the listing returned it. `depth`: the link's real depth
    /// when it is deeper than its node implies (a link inside a package, folded into the package node); default =
    /// the node's depth, +1 for a directory occurrence.
    public mutating func addLink(_ identity: FileIdentity, linkCount: UInt16, bytes: UInt64,
                                 occurrence: StorageNodeID, privateBytes: UInt64? = nil, depth: Int32? = nil) {
        let i: Int
        if let existing = linkIndex[identity] {
            i = existing
        } else {
            i = links.count
            linkIndex[identity] = i
            links.append((HardLinkGroup(identity: identity, linkCount: linkCount, allocBytes: bytes,
                                        occurrences: []), []))
        }
        links[i].group.linkCount = max(links[i].group.linkCount, linkCount)
        if let privateBytes, links[i].group.privateBytes == nil {
            links[i].group.privateBytes = privateBytes
            links[i].group.provenance = .exact
        }
        links[i].nodes.append((occurrence, depth))
    }

    /// Rolled-up copy for `.partial` events; the builder keeps filling. Copies every array (advisory cost).
    public func snapshot() -> StorageTree {
        var copy = self
        return copy.build(scanDate: Date(), lastEventId: 0)
    }

    public consuming func finalize(scanDate: Date, lastEventId: UInt64) -> StorageTree {
        build(scanDate: scanDate, lastEventId: lastEventId)
    }

    // MARK: - Private

    private mutating func append(_ record: NodeRecord, parent p: StorageNodeID) {
        parent.append(p)
        firstChild.append(0)
        childCount.append(0)
        allocBytes.append(record.allocBytes)
        smallBytes.append(0)
        smallCount.append(0)
        fileID.append(record.fileID)
        mtime.append(record.mtime)
        subtreeMaxMtime.append(record.mtime)
        addedTime.append(record.addedTime)
        flags.append(record.flags)
        markerMask.append([])
        nameOffset.append(UInt32(names.count))
        nameLength.append(UInt16(clamping: record.name.count))
        names.append(contentsOf: record.name.prefix(Int(UInt16.max)))
    }

    private mutating func build(scanDate: Date, lastEventId: UInt64) -> StorageTree {
        let n = nodeCount
        for i in 0 ..< n { allocBytes[i] += smallBytes[i] }
        let linkGroups = creditLinks()
        // Reverse pass: every child has a higher id than its parent, so a child is complete before it is added.
        // A restricted node is zeroed only now, after its own descendants were added into it, so nothing below it
        // reaches its ancestors.
        for i in stride(from: n - 1, to: 0, by: -1) {
            let p = Int(parent[i])
            if flags[i].contains(.restricted) { allocBytes[i] = 0 }
            allocBytes[p] += allocBytes[i]
            if !flags[i].contains(.buildDir) {
                subtreeMaxMtime[p] = max(subtreeMaxMtime[p], subtreeMaxMtime[i])
            }
        }
        if flags[0].contains(.restricted) { allocBytes[0] = 0 }

        var childOrder = [Int32](repeating: 0, count: n)
        var childPrefix = [UInt64](repeating: 0, count: n)
        for p in 0 ..< n where childCount[p] > 0 {
            let start = Int(firstChild[p])
            let end = start + Int(childCount[p])
            let sorted = (Int32(start) ..< Int32(end)).sorted { a, b in
                let sa = allocBytes[Int(a)], sb = allocBytes[Int(b)]
                if sa != sb { return sa > sb }
                return nameBytes(a).lexicographicallyPrecedes(nameBytes(b))
            }
            var running: UInt64 = 0
            for (k, child) in sorted.enumerated() {
                childOrder[start + k] = child
                running += allocBytes[Int(child)]
                childPrefix[start + k] = running
            }
        }

        return StorageTree(
            root: root, volumeUUID: volumeUUID, dev: dev, scanDate: scanDate, lastEventId: lastEventId,
            parent: parent, firstChild: firstChild, childCount: childCount, allocBytes: allocBytes,
            smallBytes: smallBytes, smallCount: smallCount, fileID: fileID, mtime: mtime,
            subtreeMaxMtime: subtreeMaxMtime, addedTime: addedTime, flags: flags, markerMask: markerMask,
            nameOffset: nameOffset, nameLength: nameLength, names: names, childOrder: childOrder,
            childPrefix: childPrefix, linkGroups: linkGroups
        )
    }

    /// Settles each group's occurrences (link depth, folded or kept) sorted by (depth, path), and credits the group's
    /// bytes once at the first one, so sizes don't depend on which worker saw a link first. A kept file gets the
    /// bytes as its own size; a folding dir gets them as small bytes.
    private mutating func creditLinks() -> [HardLinkGroup] {
        guard !links.isEmpty else { return [] }
        var depth = [Int32](repeating: 0, count: nodeCount)
        for i in 1 ..< nodeCount { depth[i] = depth[Int(parent[i])] + 1 }
        var groups: [HardLinkGroup] = []
        groups.reserveCapacity(links.count)
        for entry in links {
            var group = entry.group
            let keyed = entry.nodes.map { node, override -> (LinkOccurrence, [UInt8]) in
                let folded = flags[Int(node)].contains(.directory)
                let occ = LinkOccurrence(node: node, depth: override ?? depth[Int(node)] + (folded ? 1 : 0),
                                         isFolded: folded)
                return (occ, pathBytes(node))
            }
            group.occurrences = keyed.sorted { a, b in
                if a.0.depth != b.0.depth { return a.0.depth < b.0.depth }
                if a.1 != b.1 { return a.1.lexicographicallyPrecedes(b.1) }
                return !a.0.isFolded && b.0.isFolded
            }.map(\.0)
            if let first = group.occurrences.first {
                let b = Int(first.node)
                allocBytes[b] += group.allocBytes
                if first.isFolded { smallBytes[b] += group.allocBytes }
            }
            groups.append(group)
        }
        return groups
    }

    private func nameBytes(_ node: Int32) -> ArraySlice<UInt8> {
        let start = Int(nameOffset[Int(node)])
        return names[start ..< start + Int(nameLength[Int(node)])]
    }

    private func pathBytes(_ node: Int32) -> [UInt8] {
        var chain: [Int32] = []
        var n = node
        while n != 0 {
            chain.append(n)
            n = parent[Int(n)]
        }
        var bytes: [UInt8] = []
        for c in chain.reversed() {
            bytes.append(UInt8(ascii: "/"))
            bytes.append(contentsOf: nameBytes(c))
        }
        return bytes
    }
}
