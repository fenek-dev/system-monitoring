import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct SafePathTests {
    /// Temp layout: <base>/root/{real/sub/f, link → <base>/outside, leaflink → <base>/outside/f}, <base>/outside/f.
    final class Sandbox {
        let base: URL
        var root: String { base.appendingPathComponent("root").path }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("safepath-\(UUID().uuidString)")
            let fm = FileManager.default
            try fm.createDirectory(at: base.appendingPathComponent("root/real/sub"), withIntermediateDirectories: true)
            try fm.createDirectory(at: base.appendingPathComponent("outside"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: base.appendingPathComponent("root/real/sub/f"))
            try Data("secret".utf8).write(to: base.appendingPathComponent("outside/f"))
            try fm.createSymbolicLink(atPath: base.appendingPathComponent("root/link").path,
                                      withDestinationPath: base.appendingPathComponent("outside").path)
            try fm.createSymbolicLink(atPath: base.appendingPathComponent("root/leaflink").path,
                                      withDestinationPath: base.appendingPathComponent("outside/f").path)
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    /// Bug: a stale or crafted path escapes the root by spelling.
    @Test(arguments: ["../x", "a/../b", "./a", "a/.", "a//b", "a/", "", "a\u{0}b", "/abs"])
    func rejectsBadSpelling(_ path: String) {
        #expect(throws: SafePathError.self) { try RelativePath(validating: path) }
    }

    /// Bug: string-prefix confinement treats `/x/ab` as inside `/x/a`.
    @Test func confinementComparesWholeComponents() throws {
        #expect(throws: SafePathError.outsideRoot) { try RelativePath.confined("/x/ab/f", under: "/x/a") }
        #expect(throws: SafePathError.outsideRoot) { try RelativePath.confined("/x/a", under: "/x/a") }
        #expect(throws: SafePathError.self) { try RelativePath.confined("/x/a/../b", under: "/x/a") }
        #expect(try RelativePath.confined("/x/a/b/c", under: "/x/a/").components == ["b", "c"])
    }

    /// Bug: a symlink inside the root (mid-path or final) redirects an open outside it.
    @Test(arguments: [TrustedRoot.Resolution.automatic, .componentWalk])
    func symlinksRefusedInBothModes(_ resolution: TrustedRoot.Resolution) throws {
        let box = try Sandbox()
        let root = try TrustedRoot(path: box.root, resolution: resolution)
        // This Mac (macOS 26) passes the probes, so `.automatic` really exercises the kernel flags.
        #expect(root.usesKernelResolution == (resolution == .automatic))
        _ = try root.open(RelativePath(validating: "real/sub/f"), flags: O_RDONLY)
        for path in ["link/f", "leaflink"] {
            do {
                _ = try root.open(RelativePath(validating: path), flags: O_RDONLY)
                Issue.record("\(path) opened through a symlink")
            } catch {
                #expect([ELOOP, ENOTDIR].contains(error.errno ?? 0), "\(path): \(error)")
            }
        }
        #expect(throws: SafePathError.self) { _ = try root.openParent(RelativePath(validating: "link/f")) }
    }

    /// Bug: the identity chain skips or misreports an ancestor, so an "inside protected dir" check passes wrongly.
    @Test func chainHoldsEveryOpenedLevel() throws {
        let box = try Sandbox()
        let root = try TrustedRoot(path: box.root, resolution: .automatic)
        let opened = try root.openWithChain(RelativePath(validating: "real/sub/f"), flags: O_RDONLY)
        let expected = try ["real", "real/sub", "real/sub/f"].map { rel in
            var st = stat()
            guard lstat(box.root + "/" + rel, &st) == 0 else { throw SafePathError.posix(op: "lstat", errno: errno) }
            return FileIdentity(st)
        }
        #expect(opened.chain == expected)
        let fdIdentity = try opened.fd.identity()
        #expect(fdIdentity == expected[2])
        #expect(root.chain.last == root.identity)
        #expect(root.chain.count == root.canonicalPath.split(separator: "/").count + 1)
        #expect(try root.relativePath(of: box.root + "/real/sub").components == ["real", "sub"])
        #expect(try root.relativePath(of: root.canonicalPath + "/real").components == ["real"])
    }
}
