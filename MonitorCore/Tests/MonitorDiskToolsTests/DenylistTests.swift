import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct DenylistTests {
    private func denylist(_ box: CleanSandbox, scanRoot: String? = nil) -> Denylist {
        Denylist.build(home: box.home, scanRoot: scanRoot ?? box.home, dataDirectories: [box.appData])
    }

    private func check(_ list: Denylist, _ box: CleanSandbox, _ rel: String) throws -> DenyReason? {
        list.check(root: try TrustedRoot(path: box.base), target: box.path(rel))
    }

    /// Bug: protection decided from scan data. Here the protected data dir is a child of the target and is not in
    /// any tree: only the live identity chain can see it.
    @Test func targetContainingInjectedDataDirectoryIsProtected() throws {
        let box = try CleanSandbox()
        try box.makeDir("home/Library/Caches/Foo/inner-data")
        try box.makeDir("home/Library/Caches/Bar")
        let list = Denylist.build(home: box.home, scanRoot: box.home,
                                  dataDirectories: [box.path("home/Library/Caches/Foo/inner-data")])

        #expect(try check(list, box, "home/Library/Caches/Foo") == .protected)
        #expect(try check(list, box, "home/Library/Caches/Foo/inner-data") == .protected)
        // Negative control: an unrelated cache is allowed (a deny-everything bug must fail here).
        #expect(try check(list, box, "home/Library/Caches/Bar") == nil)
    }

    /// Bug: "inside" a protected directory is not checked, only the directory itself.
    @Test func fileInsideKeychainsIsProtected() throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Keychains/login.keychain-db")
        #expect(try check(denylist(box), box, "home/Library/Keychains/login.keychain-db") == .protected)
    }

    /// Bug: the home folder, ~/Library, their parents or direct children of ~/Library can be cleaned.
    @Test func anchorsAreRefusedAsTargetsAndAsAncestors() throws {
        let box = try CleanSandbox()
        let list = denylist(box)
        #expect(try check(list, box, "home") == .anchor)
        #expect(try check(list, box, "home/Library") == .anchor)
        #expect(try check(list, box, "home/Library/Caches") == .anchor)
        // The parent of ~ contains it.
        let parent = try TrustedRoot(path: (box.base as NSString).deletingLastPathComponent)
        #expect(list.check(root: parent, target: box.base) == .anchor)
    }

    /// Bug: a case spelling of a protected path slips past a string comparison.
    @Test(.enabled(if: Self.volumeIsCaseInsensitive, "temp volume is case-sensitive"))
    func caseVariantResolvesToTheSameIdentity() throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Keychains/k")

        #expect(try check(denylist(box), box, "home/Library/Keychains/k") == .protected)
        #expect(try check(denylist(box), box, "home/LIBRARY/KEYCHAINS/k") == .protected)
    }

    /// Bug: a Unicode-normalization (NFD) spelling of a protected path slips past a string comparison.
    @Test(.enabled(if: Self.volumeNormalizesUnicode, "temp volume does not treat NFC and NFD names as the same"))
    func normalizationVariantResolvesToTheSameIdentity() throws {
        let box = try CleanSandbox()
        try box.makeDir("appdata/Caf\u{E9}")
        let list = Denylist.build(home: box.home, scanRoot: box.home, dataDirectories: [box.path("appdata/Caf\u{E9}")])

        #expect(try check(list, box, "appdata/Caf\u{E9}") == .protected)
        #expect(try check(list, box, "appdata/Cafe\u{301}") == .protected)
    }

    /// Bug: a symlink directly under ~/Library is anchored only by the directory it points to, so the link itself
    /// (what a target path names) can be trashed.
    @Test func symlinkAnchorIsDeniedByItsOwnIdentity() throws {
        let box = try CleanSandbox()
        try box.makeDir("home/Elsewhere")
        #expect(symlink(box.path("home/Elsewhere"), box.path("home/Library/Linked")) == 0)

        #expect(try check(denylist(box), box, "home/Library/Linked") == .anchor)
    }

    private static let volumeIsCaseInsensitive: Bool = probe { dir in
        FileManager.default.createFile(atPath: dir + "/Probe", contents: nil) && access(dir + "/pROBE", F_OK) == 0
    }

    private static let volumeNormalizesUnicode: Bool = probe { dir in
        FileManager.default.createFile(atPath: dir + "/Caf\u{E9}", contents: nil) && access(dir + "/Cafe\u{301}", F_OK) == 0
    }

    private static func probe(_ body: (String) -> Bool) -> Bool {
        let dir = NSTemporaryDirectory() + "w2c-probe-\(UUID().uuidString)"
        guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return body(dir)
    }

    /// Bug: the scan root's own ancestors are not part of the chain, so a root inside Mail is not protected.
    @Test func scanRootInsideProtectedDirectoryProtectsDescendants() throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Mail/V10/messages/a.emlx")
        let root = box.path("home/Library/Mail/V10")
        let list = denylist(box, scanRoot: root)

        let reason = list.check(root: try TrustedRoot(path: root), target: root + "/messages/a.emlx")

        #expect(reason == .protected)
    }

    /// Bug: an unreadable ancestor is treated as "no protected path here" instead of refusing.
    @Test func unreadableAncestorIsUnverifiable() throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/locked/inner/file")
        let list = denylist(box)
        #expect(chmod(box.path("home/Documents/locked"), 0o000) == 0)

        #expect(try check(list, box, "home/Documents/locked/inner/file") == .unverifiable)
    }

    /// Bug: the UI snapshot maps denylist paths to the wrong nodes (advisory, but it drives disabled buttons).
    @Test func policyMapsAnchorsAndProtectedPathsToNodes() throws {
        let box = try CleanSandbox()
        let tree = box.tree([
            TreeFixture.dir("Library", [
                TreeFixture.dir("Keychains", [TreeFixture.file("k", 10)]),
                TreeFixture.dir("Caches", [TreeFixture.dir("Foo", [TreeFixture.file("f", 10)])]),
            ]),
        ])
        let list = denylist(box)
        let policy = list.policy(for: tree)

        let library = try #require(tree.lookup(path: box.home + "/Library"))
        let keychains = try #require(tree.lookup(path: box.home + "/Library/Keychains"))
        let foo = try #require(tree.lookup(path: box.home + "/Library/Caches/Foo"))
        #expect(policy.treeVersion == tree.version)
        #expect(policy.denyReason(trash: library, in: tree) == .anchor)
        // Keychains is not on disk here, so it is a protected path only (anchors list ~/Library live).
        #expect(policy.denyReason(trash: keychains, in: tree) == .protected)
        #expect(policy.denyReason(trash: foo, in: tree) == nil)
        let keyFile = try #require(tree.lookup(path: box.home + "/Library/Keychains/k"))
        #expect(policy.denyReason(trash: keyFile, in: tree) == .protected)
    }
}
