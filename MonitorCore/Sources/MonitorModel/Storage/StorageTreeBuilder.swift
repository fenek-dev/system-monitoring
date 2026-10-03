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
    private var linkGroups: [HardLinkGroup] = []
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

    /// Records one observed link of a hard-linked file; `occurrence` is its file node if kept, else its dir node.
    /// The bytes are not part of any `NodeRecord.allocBytes` / `addSmall`; `finalize` credits them once.
    public mutating func addLink(_ identity: FileIdentity, linkCount: UInt16, bytes: UInt64,
                                 occurrence: StorageNodeID) {
        if let i = linkIndex[identity] {
            linkGroups[i].occurrences.append(occurrence)
        } else {
            linkIndex[identity] = linkGroups.count
            linkGroups.append(HardLinkGroup(identity: identity, linkCount: linkCount, bytes: bytes,
                                            occurrences: [occurrence]))
        }
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
        for i in 0 ..< n {
            if flags[i].contains(.restricted) {
                allocBytes[i] = 0
            } else {
                allocBytes[i] += smallBytes[i]
            }
        }
        creditLinks()
        // Reverse pass: every child has a higher id than its parent, so a child is complete before it is added.
        for i in stride(from: n - 1, to: 0, by: -1) {
            let p = Int(parent[i])
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

    /// Credits each hard-link group's bytes once, at its lowest-depth occurrence (ties by path), so sizes don't
    /// depend on which worker saw a link first. A file occurrence gets the bytes as its own size; a dir occurrence
    /// (folded small file) gets them as small bytes.
    private mutating func creditLinks() {
        guard !linkGroups.isEmpty else { return }
        var depth = [Int](repeating: 0, count: nodeCount)
        for i in 1 ..< nodeCount { depth[i] = depth[Int(parent[i])] + 1 }
        for group in linkGroups {
            guard var best = group.occurrences.first else { continue }
            for occ in group.occurrences.dropFirst() where occ != best {
                let (d, db) = (depth[Int(occ)], depth[Int(best)])
                if d < db || (d == db && pathBytes(occ).lexicographicallyPrecedes(pathBytes(best))) { best = occ }
            }
            let b = Int(best)
            if flags[b].contains(.restricted) { continue }
            if !flags[b].contains(.directory) {
                allocBytes[b] += group.bytes
            } else {
                smallBytes[b] += group.bytes
                allocBytes[b] += group.bytes
            }
        }
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
