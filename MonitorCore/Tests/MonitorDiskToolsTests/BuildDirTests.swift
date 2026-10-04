import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct BuildDirTests {
    typealias F = ClassifierFixture
    typealias T = TreeFixture

    enum Place { case home, library, cargo }

    struct Case: CustomTestStringConvertible {
        var label: String
        var name = "node_modules"
        var markers: StorageMarker = .npmLock
        var hasGit = true
        var projectDays = 40.0
        var place = Place.home
        var tracked = false
        var gitFailsClosed = false
        var xcodeOK = true
        var unreadableSibling = false
        var expected: Bool
        var testDescription: String { label }
    }

    /// Bug caught: a tracked `build/` (or one in an active / non-git / system location) offered for deletion.
    @Test(arguments: [
        Case(label: "ok", expected: true),
        Case(label: "target with CACHEDIR.TAG", name: "target", markers: .cachedirTag, expected: true),
        Case(label: "cmake-build-debug", name: "cmake-build-debug", markers: .cmakeCache, expected: true),
        Case(label: "no tool marker", markers: [], expected: false),
        Case(label: "wrong tool marker", markers: .podsManifest, expected: false),
        Case(label: "no .git ancestor", hasGit: false, expected: false),
        Case(label: "project touched 10 d ago", projectDays: 10, expected: false),
        Case(label: "under ~/Library", place: .library, expected: false),
        Case(label: "under ~/.cargo", place: .cargo, expected: false),
        Case(label: "git tracks files", tracked: true, expected: false),
        Case(label: "git timeout or error", gitFailsClosed: true, expected: false),
        Case(label: "no developer tools", xcodeOK: false, expected: false),
        // Its age comes from a tree that could not be read completely.
        Case(label: "project has unreadable subdir", unreadableSibling: true, expected: false),
    ])
    func buildDir(_ c: Case) {
        let build = T.dir(c.name, flags: .buildDir, markers: c.markers, mtime: F.ago(1),
                          [T.small(bytes: 9000, maxMtime: F.ago(1))])
        let project = T.dir("proj", markers: c.hasGit ? .git : [], mtime: F.ago(c.projectDays),
                            [build] + (c.unreadableSibling ? [.restricted("private")] : []))
        let entries: [T.Entry] = switch c.place {
        case .home: [project]
        case .library: [T.dir("Library", [project])]
        case .cargo: [T.dir(".cargo", [project])]
        }
        let dir = switch c.place {
        case .home: "/Users/test/proj/\(c.name)"
        case .library: "/Users/test/Library/proj/\(c.name)"
        case .cargo: "/Users/test/.cargo/proj/\(c.name)"
        }
        let git = FakeGit(tracked: c.tracked ? [dir] : [], failClosed: c.gitFailsClosed)
        let result = F.classify(entries, classifier: F.classifier(git: git, devTools: FakeDevTools(xcodeSelectOK: c.xcodeOK)))

        #expect(F.paths(result.set, .developer) == (c.expected ? [dir] : []))
        if c.expected {
            #expect(result.set.items.map(\.tier) == [.review])
            #expect(result.set.items.map(\.mode) == [.remove])
        }
    }

    /// Bug caught: a fresh `npm install` inside a stale project counted as project activity (build dir mtime
    /// leaking into the project's last-touched time).
    @Test func freshBuildOutputDoesNotKeepProjectAlive() {
        let build = T.dir("node_modules", flags: .buildDir, markers: .npmLock, mtime: F.ago(0), [T.small(bytes: 500)])
        let project = T.dir("proj", markers: .git, mtime: F.ago(100), [build, T.small(bytes: 100, maxMtime: F.ago(100))])
        let result = F.classify([project])
        #expect(F.paths(result.set, .developer) == ["/Users/test/proj/node_modules"])
    }

    /// Bug caught: a huge file inside a build dir offered separately from (and on top of) the build dir.
    @Test func largeFileInsideBuildDirIsNotASecondItem() {
        let build = T.dir("node_modules", flags: .buildDir, markers: .npmLock, mtime: F.ago(1),
                          [T.file("blob", 600_000_000, mtime: F.ago(1))])
        let project = T.dir("proj", markers: .git, mtime: F.ago(100), [build, T.file("movie", 700_000_000, mtime: F.ago(100))])
        let result = F.classify([project])
        #expect(F.paths(result.set) == ["/Users/test/proj/movie", "/Users/test/proj/node_modules"])
    }

    // MARK: Live git

    private static func git(_ args: [String]) throws {
        let out = try ProcessRun.run("/usr/bin/git", args, timeout: 20)
        #expect(out.status == 0)
    }

    /// Bug caught: wrong `git ls-files` invocation (relative path, `--`, exit handling) making every build dir look
    /// tracked or untracked.
    @Test(.enabled(if: LiveDevToolProbe().xcodeSelectOK)) func liveGitTracking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        // Pathspec magic as directory names: `*` globs over `tracked/f`, `:(top)tracked` names it.
        for dir in ["tracked", "untracked", "*", ":(top)tracked"] {
            try fm.createDirectory(atPath: root + "/repo/\(dir)", withIntermediateDirectories: true)
            fm.createFile(atPath: root + "/repo/\(dir)/f", contents: Data("x".utf8))
        }
        try Self.git(["-C", root + "/repo", "init", "-q"])
        try Self.git(["-C", root + "/repo", "add", "tracked/f"])

        let live = LiveGitTracking()
        #expect(live.hasTrackedFiles(project: root + "/repo", dir: root + "/repo/tracked"))
        #expect(!live.hasTrackedFiles(project: root + "/repo", dir: root + "/repo/untracked"))
        #expect(!live.hasTrackedFiles(project: root + "/repo", dir: root + "/repo/*"))
        #expect(!live.hasTrackedFiles(project: root + "/repo", dir: root + "/repo/:(top)tracked"))
        // Not a repository: git exits 128, which must read as "tracked".
        #expect(live.hasTrackedFiles(project: root, dir: root + "/repo/untracked"))
    }
}
