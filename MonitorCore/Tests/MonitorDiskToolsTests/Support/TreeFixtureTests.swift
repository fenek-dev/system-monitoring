import Foundation
import MonitorModel
import Testing

/// The DSL every DiskTools suite builds trees with.
@Suite struct TreeFixtureTests {
    /// Bug: a kept link's node carries a generated inode (or collides with one), so identity-based checks in W2
    /// tests compare against the wrong file; folded links don't count as small files.
    @Test func linksShareTheSuppliedInode() {
        let tree = TreeFixture.build([
            TreeFixture.link("a", ino: 7, bytes: 1000),
            TreeFixture.dir("b", [TreeFixture.link(nil, ino: 7, bytes: 1000), TreeFixture.file("f", 5)]),
        ])
        let a = tree.lookup(path: "/Users/test/a")
        let b = tree.lookup(path: "/Users/test/b")
        let group = tree.linkGroups[0]
        #expect(tree.linkGroups.count == 1)
        #expect(a.map { tree.identity($0) } == group.identity)
        #expect(group.occurrences.map(\.node) == [a, b].compactMap { $0 })
        #expect(b.map { tree.smallCount[Int($0)] } == 1)
        #expect(Set(tree.fileID).count == tree.nodeCount)
        #expect(tree.size(0) == 1005)
    }
}
