import Foundation
import Testing
@testable import MonitorModel

/// Tree: root(/Users/t) → Library → Caches → { app (dir: blob 40, small 10), old 30 }; root → f 20.
@Suite struct StorageOverlayTests {
    typealias T = StorageTreeTests

    struct Fixture {
        let tree: StorageTree
        let library: StorageNodeID, caches: StorageNodeID, app: StorageNodeID, blob: StorageNodeID
        let old: StorageNodeID
    }

    static func fixture() -> Fixture {
        var b = T.builder()
        let top = b.appendChildren(of: 0, [T.dir("Library"), T.file("f", 20)])
        let caches = b.appendChildren(of: top.lowerBound, [T.dir("Caches")]).lowerBound
        let kids = b.appendChildren(of: caches, [T.dir("app"), T.file("old", 30)])
        let blob = b.appendChildren(of: kids.lowerBound, [T.file("blob", 40)]).lowerBound
        b.addSmall(kids.lowerBound, bytes: 10, count: 3, maxMtime: 0)
        return Fixture(tree: T.finalize(b), library: top.lowerBound, caches: caches, app: kids.lowerBound,
                       blob: blob, old: kids.lowerBound + 1)
    }

    static func entry(_ parent: StorageNodeID, _ name: String) -> RestoredEntry {
        RestoredEntry(parent: parent, name: name, bytes: 0, itemID: 0)
    }

    /// Bug: a keep-parent clean drops the cache dir that is still on disk.
    @Test func shrinkKeepsParent() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.shrink(f.app, by: 10, in: f.tree)
        #expect(try !o.isRemoved(f.app, in: f.tree))
        #expect(try o.size(f.app, in: f.tree) == 40)
        #expect(try o.size(f.library, in: f.tree) == 70)
        #expect(try o.size(0, in: f.tree) == 90)
    }

    /// Bug: negative / wrapped totals after over-reported partial removals and clean + undo.
    @Test func sizesSaturateAtZero() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.shrink(f.app, by: 500, in: f.tree)
        #expect(try o.size(f.app, in: f.tree) == 0)
        #expect(try o.size(f.caches, in: f.tree) == 30)
        #expect(try o.size(0, in: f.tree) == 50)
        try o.remove(f.app, kind: .deleted, in: f.tree)
        #expect(try o.size(0, in: f.tree) == 50)
    }

    /// Bug: 64-bit signed deltas clamp sizes above Int64.max, and sums past UInt64.max wrap.
    @Test func byteMathIsExactPastInt64AndUInt64() throws {
        let big = UInt64(Int64.max) + 11
        var b = T.builder()
        let kids = b.appendChildren(of: 0, [T.file("big", big), T.file("one", 1)])
        let tree = T.finalize(b)
        var o = StorageTreeOverlay(tree: tree)
        try o.shrink(kids.lowerBound, by: 5, in: tree)
        #expect(try o.size(kids.lowerBound, in: tree) == big - 5)
        #expect(try o.size(0, in: tree) == big - 4)
        try o.restore(RestoredEntry(parent: 0, name: "huge", bytes: .max, itemID: 1), originalNode: nil, in: tree)
        #expect(try o.size(0, in: tree) == .max)                          // past UInt64.max, clamped on read
        try o.remove(kids.lowerBound, kind: .deleted, in: tree)
        try o.remove(kids.lowerBound + 1, kind: .deleted, in: tree)
        #expect(try o.size(0, in: tree) == .max)                          // exactly UInt64.max: only "huge" left
        try o.shrink(0, by: 1, in: tree)
        #expect(try o.size(0, in: tree) == .max - 1)
    }

    /// Bug: an overlay applied to another tree (or a sidecar to another scan, or a decoded one before rebasing)
    /// shifts sizes onto unrelated nodes.
    @Test func rejectsOtherTrees() throws {
        let f = Self.fixture()
        let other = Self.fixture().tree                                  // same scan, new version
        var o = StorageTreeOverlay(tree: f.tree)
        try o.remove(f.old, kind: .trashed, in: f.tree)
        #expect(throws: StorageOverlayError.treeMismatch) { try o.remove(f.app, kind: .deleted, in: other) }
        #expect(throws: StorageOverlayError.treeMismatch) { try o.size(0, in: other) }
        let decoded = try JSONDecoder().decode(StorageTreeOverlay.self, from: JSONEncoder().encode(o))
        #expect(throws: StorageOverlayError.treeMismatch) { try decoded.size(0, in: f.tree) }
        #expect(try decoded.rebased(onto: other).size(0, in: other) == 70)
        var b = T.builder()
        b.appendChildren(of: 0, [T.file("x", 1)])
        #expect(throws: StorageOverlayError.treeMismatch) { try o.rebased(onto: T.finalize(b)) }
    }

    /// Review r2 (a): a renamed undo of the link that held the map credit counted the file twice (root 200).
    @Test func renamedUndoOfCreditedLinkCountsOnce() throws {
        var b = T.builder()
        let top = b.appendChildren(of: 0, [T.dir("A"), T.dir("B")])
        let (a, bDir) = (top.lowerBound, top.lowerBound + 1)
        let x = b.appendChildren(of: a, [T.file("x", 0)]).lowerBound
        let y = b.appendChildren(of: b.appendChildren(of: bDir, [T.dir("C")]).lowerBound, [T.file("y", 0)])
            .lowerBound
        let id = FileIdentity(dev: 1, ino: 9, isDirectory: false)
        b.addLink(id, linkCount: 2, bytes: 100, occurrence: y)
        b.addLink(id, linkCount: 2, bytes: 100, occurrence: x)
        let tree = T.finalize(b)
        var o = StorageTreeOverlay(tree: tree)
        try o.remove(a, kind: .trashed, in: tree)
        #expect(try o.size(bDir, in: tree) == 100)
        try o.restore(RestoredEntry(parent: 0, name: "A (restored)", bytes: 100, itemID: 1), originalNode: a,
                      in: tree)
        #expect(try o.size(0, in: tree) == 100)
        #expect(try o.size(a, in: tree) == 100)
        #expect(try o.size(bDir, in: tree) == 0)
        #expect(try o.name(a, in: tree) == "A (restored)")
    }

    /// Review r2 (b): restoring into a recreated dir that once held a folded link's credit lost unrelated bytes
    /// (A = 0, root = 50).
    @Test func recreatedFoldedHolderKeepsRestoredBytes() throws {
        var b = T.builder()
        let top = b.appendChildren(of: 0, [T.dir("A"), T.dir("B")])
        let (a, bDir) = (top.lowerBound, top.lowerBound + 1)
        let z = b.appendChildren(of: a, [T.file("z", 50)]).lowerBound
        let y = b.appendChildren(of: bDir, [T.file("y", 0)]).lowerBound
        let id = FileIdentity(dev: 1, ino: 9, isDirectory: false)
        b.addLink(id, linkCount: 2, bytes: 100, occurrence: a)              // folded into A: credited ("/A" < "/B/y")
        b.addLink(id, linkCount: 2, bytes: 100, occurrence: y)
        let tree = T.finalize(b)
        #expect(tree.size(a) == 150)
        var o = StorageTreeOverlay(tree: tree)
        for node in [z, bDir, a] { try o.remove(node, kind: .trashed, in: tree) }
        try o.restore(Self.entry(a, "z"), originalNode: z, in: tree)
        try o.restore(Self.entry(0, "B"), originalNode: bDir, in: tree)
        #expect(try o.size(a, in: tree) == 50)
        #expect(try o.size(0, in: tree) == 150)
    }

    /// Review r2 (c): deleting a recreated dir again and restoring a sibling resurrected the first restored child.
    @Test func repeatedParentRemovalKeepsDeletedChildrenGone() throws {
        var b = T.builder()
        let p = b.appendChildren(of: 0, [T.dir("P"), T.file("f", 5)]).lowerBound
        let kids = b.appendChildren(of: p, [T.file("c1", 30), T.file("c2", 10), T.file("s", 20)])
        let (c1, c2) = (kids.lowerBound, kids.lowerBound + 1)
        let tree = T.finalize(b)
        var o = StorageTreeOverlay(tree: tree)
        try o.remove(c1, kind: .trashed, in: tree)
        try o.remove(c2, kind: .trashed, in: tree)
        try o.remove(p, kind: .deleted, in: tree)
        try o.restore(Self.entry(p, "c1"), originalNode: c1, in: tree)
        try o.remove(p, kind: .deleted, in: tree)
        try o.restore(Self.entry(p, "c2"), originalNode: c2, in: tree)
        #expect(try o.isRemoved(c1, in: tree))
        #expect(try o.size(p, in: tree) == 10)
        #expect(try o.size(0, in: tree) == 15)
    }

    /// Bug class: any incremental drift between removals, undo (original or renamed name), recreated parents and
    /// hard-link credit. Random sequences on random trees against a brute-force model of the disk.
    @Test(arguments: 0 ..< 150)
    func matchesBruteForceModel(seed: Int) throws {
        var rng = SplitMix64(seed: UInt64(seed))
        let world = RefWorld(rng: &rng)
        var o = StorageTreeOverlay(tree: world.tree)
        try world.check(o, step: -1, seed: seed)
        for step in 0 ..< 40 {
            let candidates = world.restorable()
            if candidates.isEmpty || rng.next() % 10 < 6 {
                let visible = world.visibleNodes().filter { $0 != 0 }
                guard !visible.isEmpty else { break }
                let node = visible[Int(rng.next() % UInt64(visible.count))]
                let kind: StorageTreeOverlay.RemovalKind = rng.next() % 2 == 0 ? .deleted : .trashed
                world.remove(node, kind: kind)
                try o.remove(node, kind: kind, in: world.tree)
            } else {
                let node = candidates[Int(rng.next() % UInt64(candidates.count))]
                let name = world.tree.name(node) + (rng.next() % 2 == 0 ? "" : " (restored)")
                world.restore(node, as: name)
                try o.restore(RestoredEntry(parent: world.tree.parent[Int(node)], name: name, bytes: 0, itemID: 0),
                              originalNode: node, in: world.tree)
            }
            try world.check(o, step: step, seed: seed)
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Brute-force model: a forest of physical items (live tree + Trash snapshots), each tied to the tree node it came
/// from. Sizes are summed from scratch; a link group's bytes sit at its live occurrence with the smallest original
/// (depth, path) key — the tree's credit rule, computed here from the generated layout, not from the tree.
final class RefWorld {
    final class Item {
        let node: StorageNodeID
        var name: String
        let ownBytes: UInt64
        var smallBytes: UInt64 = 0
        /// (group ino, original sort key) of a kept link file.
        let links: [(ino: UInt64, key: String)]
        /// Links folded into this dir.
        var folded: [(ino: UInt64, key: String)] = []
        var children: [Item] = []

        init(node: StorageNodeID, name: String, ownBytes: UInt64, links: [(ino: UInt64, key: String)]) {
            self.node = node
            self.name = name
            self.ownBytes = ownBytes
            self.links = links
        }

        var allLinks: [(ino: UInt64, key: String)] { links + folded }

        func all() -> [Item] { [self] + children.flatMap { $0.all() } }

        func find(_ node: StorageNodeID) -> (parent: Item, index: Int)? {
            if let i = children.firstIndex(where: { $0.node == node }) { return (self, i) }
            for child in children { if let hit = child.find(node) { return hit } }
            return nil
        }
    }

    static func key(depth: Int, path: String) -> String { String(format: "%03d", depth) + path }

    let tree: StorageTree
    let root: Item
    var trash: [(seq: Int, item: Item)] = []
    var seq = 0
    let groupBytes: [UInt64: UInt64]
    let groupTotal: [UInt64: Int]

    init(rng: inout SplitMix64) {
        var builder = StorageTreeBuilder(root: .home("/r"), dev: 1, volumeUUID: nil)
        var groupBytes: [UInt64: UInt64] = [:]
        for g in 0 ..< 3 { groupBytes[1000 + UInt64(g)] = 100 * (rng.next() % 9 + 1) }
        var groupTotal: [UInt64: Int] = [:]
        // Pending per dir: (dir node, its Item, depth, path).
        let rootItem = Item(node: 0, name: "r", ownBytes: 0, links: [])
        var queue: [(StorageNodeID, Item, Int, String)] = [(0, rootItem, 0, "")]
        var pendingLinks: [(UInt64, StorageNodeID)] = []
        while !queue.isEmpty {
            let (node, item, depth, path) = queue.removeFirst()
            let count = depth == 0 ? 4 : Int(rng.next() % 4)
            var records: [NodeRecord] = []
            var specs: [(kind: Int, name: String, bytes: UInt64, ino: UInt64)] = []
            for c in 0 ..< count {
                let roll = rng.next() % 20
                let kind = depth < 3 && roll < 8 ? 0 : (roll < 15 ? 1 : 2)          // 0 dir, 1 file, 2 kept link
                let name = "n\(c)"
                let bytes = kind == 1 ? rng.next() % 1000 : 0
                let ino = kind == 2 ? 1000 + rng.next() % 3 : 0
                specs.append((kind, name, bytes, ino))
                records.append(NodeRecord(name: name, flags: kind == 0 ? .directory : [], allocBytes: bytes,
                                          fileID: 0, mtime: 0, addedTime: 0))
            }
            let range = builder.appendChildren(of: node, records)
            if node != 0 {
                let small = rng.next() % 3 == 0 ? rng.next() % 50 : 0
                builder.addSmall(node, bytes: small, count: 1, maxMtime: 0)
                item.smallBytes = small
                if rng.next() % 4 == 0 {
                    let ino = 1000 + rng.next() % 3
                    pendingLinks.append((ino, node))
                    item.folded.append((ino, Self.key(depth: depth + 1, path: path)))
                }
            }
            for (k, spec) in specs.enumerated() {
                let child = range.lowerBound + Int32(k)
                let childPath = path + "/" + spec.name
                let links = spec.kind == 2 ? [(spec.ino, Self.key(depth: depth + 1, path: childPath))] : []
                let childItem = Item(node: child, name: spec.name, ownBytes: spec.bytes, links: links)
                item.children.append(childItem)
                if spec.kind == 0 { queue.append((child, childItem, depth + 1, childPath)) }
                if spec.kind == 2 { pendingLinks.append((spec.ino, child)) }
            }
        }
        for (ino, node) in pendingLinks {
            builder.addLink(FileIdentity(dev: 1, ino: ino, isDirectory: false), linkCount: 9,
                            bytes: groupBytes[ino] ?? 0, occurrence: node)
            groupTotal[ino, default: 0] += 1
        }
        tree = builder.finalize(scanDate: Date(timeIntervalSince1970: 0), lastEventId: 0)
        root = rootItem
        self.groupBytes = groupBytes
        self.groupTotal = groupTotal
    }

    func visibleNodes() -> [StorageNodeID] { root.all().map(\.node) }

    func restorable() -> [StorageNodeID] {
        let visible = Set(visibleNodes())
        return Array(Set(trash.map(\.item.node)).subtracting(visible)).sorted()
    }

    func remove(_ node: StorageNodeID, kind: StorageTreeOverlay.RemovalKind) {
        guard let (parent, index) = root.find(node) else { return }
        let item = parent.children.remove(at: index)
        if kind == .trashed {
            trash.append((seq, item))
            seq += 1
        }
    }

    /// Latest snapshot of `node` back under its original parent; missing ancestors made as empty dirs.
    func restore(_ node: StorageNodeID, as name: String) {
        guard let index = trash.lastIndex(where: { $0.item.node == node }) else { return }
        let item = trash.remove(at: index).item
        var chain: [StorageNodeID] = []
        var m = tree.parent[Int(node)]
        while m != 0 {
            chain.append(m)
            m = tree.parent[Int(m)]
        }
        var current = root
        for a in chain.reversed() {
            if let existing = current.children.first(where: { $0.node == a }) {
                current = existing
            } else {
                let made = Item(node: a, name: tree.name(a), ownBytes: 0, links: [])
                current.children.append(made)
                current = made
            }
        }
        item.name = name
        current.children.append(item)
    }

    func check(_ o: StorageTreeOverlay, step: Int, seed: Int) throws {
        let live = root.all()
        // Credit: per group, the live link with the smallest original key.
        var holder: [UInt64: (key: String, node: StorageNodeID)] = [:]
        for item in live {
            for link in item.allLinks where holder[link.ino].map({ link.key < $0.key }) ?? true {
                holder[link.ino] = (link.key, item.node)
            }
        }
        var sizes: [StorageNodeID: UInt64] = [:]
        func total(_ item: Item) -> UInt64 {
            var t = item.ownBytes + item.smallBytes + item.children.reduce(0) { $0 + total($1) }
            for (ino, h) in holder where h.node == item.node { t += groupBytes[ino] ?? 0 }
            sizes[item.node] = t
            return t
        }
        _ = total(root)
        let names = Dictionary(live.map { ($0.node, $0.name) }, uniquingKeysWith: { a, _ in a })
        let context = "seed \(seed) step \(step)"
        for n in 0 ..< Int32(tree.nodeCount) {
            #expect(try o.isRemoved(n, in: tree) == (sizes[n] == nil), "\(context) node \(n) visibility")
            #expect(try o.size(n, in: tree) == sizes[n], "\(context) node \(n) size")
            if let name = names[n], n != 0 { #expect(try o.name(n, in: tree) == name, "\(context) node \(n) name") }
        }
        var inTrash: [UInt64: Int] = [:]
        for (_, item) in trash { for i in item.all() { for l in i.allLinks { inTrash[l.ino, default: 0] += 1 } } }
        var liveLinks: [UInt64: Int] = [:]
        for i in live { for l in i.allLinks { liveLinks[l.ino, default: 0] += 1 } }
        for (g, group) in tree.linkGroups.enumerated() {
            let ino = group.identity.ino
            let deleted = (groupTotal[ino] ?? 0) - (liveLinks[ino] ?? 0) - (inTrash[ino] ?? 0)
            #expect(o.deletedLinkCount(group: Int32(g)) == deleted, "\(context) group \(ino) deleted links")
        }
    }
}
