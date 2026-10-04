import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct InUseTests {
    private static let tempVolumeIsCaseInsensitive: Bool = {
        let dir = NSTemporaryDirectory() + "w2c-case-\(UUID().uuidString)"
        guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return access(dir.uppercased(), F_OK) == 0 && access(dir.lowercased(), F_OK) == 0
    }()

    private func item(_ id: Int32, _ path: String) -> CleanupItem {
        CleanupItem(id: id, nodeID: nil, path: path, name: (path as NSString).lastPathComponent,
                    category: .userCaches, tier: .safe, mode: .remove, identity: nil, allocBytes: 1)
    }

    /// Bug: bare string-prefix matching marks `/a/bc` as in use because `/a/b/c` is held (and misses `/a/b`).
    @Test func matchesWholeComponentsOnly() {
        let source = StaticProcessPaths(paths: ["/a/b/c"])
        let checker = InUseChecker(processes: source)

        let inUse = checker.inUse([item(1, "/a/b"), item(2, "/a/bc"), item(3, "/a/b/c"), item(4, "/a/b/c/d"),
                                   item(5, "/a")])

        #expect(inUse == [1, 3, 5])
    }

    /// Bug: an item spelled with different letter case than the on-disk (kernel) path is never matched.
    @Test(.enabled(if: Self.tempVolumeIsCaseInsensitive, "temp volume is case-sensitive"))
    func matchesOnDiskCaseRegardlessOfSpelling() throws {
        let box = try CleanSandbox()
        let held = try box.write("home/Library/Caches/Busy/file.bin")
        let flipped = box.path("home/library/caches/busy")
        let checker = InUseChecker(processes: StaticProcessPaths(paths: [held]))

        #expect(checker.inUse([item(1, flipped)]) == [1])
    }

    /// Bug: the libproc vnode path retrieval is broken, so a file this process holds open is never reported.
    @Test func liveSourceSeesFileHeldByThisProcess() throws {
        let dir = try CleanSandbox()
        let held = try dir.write("held/open.bin")
        try dir.write("idle/closed.bin")
        let fd = open(held, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        let report = InUseChecker(processes: LiveProcessPathSource()).check([
            item(1, dir.path("held")), item(2, held), item(3, dir.path("idle")),
        ])

        // Item paths are canonical here, and the kernel reports canonical paths.
        #expect(report.inUse == [1, 2])
    }
}
