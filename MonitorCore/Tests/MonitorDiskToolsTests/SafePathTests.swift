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

    /// Bug: a root spelled with `..`, `.`, `//` or NUL is silently normalized by `realpath` into another directory.
    @Test(arguments: [
        ("relative/root", SafePathError.invalidPath("not absolute")),
        ("/tmp/../etc", .invalidPath("'..' component")),
        ("/tmp/./x", .invalidPath("'.' component")),
        ("/tmp//x", .invalidPath("empty component")),
        ("/tmp/", .invalidPath("empty component")),
        ("/tmp/a\u{0}b", .invalidPath("NUL in component")),
    ])
    func rootSpellingRejectedBeforeResolving(_ path: String, _ expected: SafePathError) {
        #expect(throws: expected) { _ = try TrustedRoot(path: path) }
    }

    /// Bug: a symlink inside the root (mid-path or final) redirects an open outside it — with the kernel flags,
    /// with the walk, and when a failed launch probe makes `.automatic` fall back to the walk.
    /// `probe` nil = this machine's real probe result.
    @Test(arguments: [(TrustedRoot.Resolution.automatic, Bool?.none), (.componentWalk, nil), (.automatic, false)])
    func symlinksRefusedInEveryMode(_ resolution: TrustedRoot.Resolution, probe: Bool?) throws {
        let box = try Sandbox()
        let probePassed = probe ?? TrustedRoot.kernelResolutionAvailable
        let root = try TrustedRoot(path: box.root, resolution: resolution, probePassed: probePassed)
        #expect(root.usesKernelResolution == (resolution == .automatic && probePassed))
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

    /// Kernel `probePassed: true` above is injected; this checks the real probe on this machine.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
    struct KernelProbeSmokeTests {
        /// Bug: the launch probe fails on a kernel that honors the flags (every open silently takes the slow walk).
        /// Measured on macOS 26.5 (spikes §1); 15.x unverified.
        @Test func kernelResolutionAvailableHere() {
            #expect(TrustedRoot.kernelResolutionAvailable)
        }
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
