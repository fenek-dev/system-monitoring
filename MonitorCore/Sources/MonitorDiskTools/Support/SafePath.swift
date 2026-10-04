import Darwin
import Foundation
import MonitorModel

/// A path below a root, validated by spelling: no `..`, `.`, empty components, NUL, or leading `/`.
public struct RelativePath: Hashable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(validating path: String) throws(SafePathError) {
        guard !path.isEmpty else { throw .invalidPath("empty path") }
        guard !path.hasPrefix("/") else { throw .invalidPath("absolute path") }
        try self.init(components: path.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    public init(components: [String]) throws(SafePathError) {
        guard !components.isEmpty else { throw .invalidPath("empty path") }
        for c in components {
            if c.isEmpty { throw .invalidPath("empty component") }
            if c == "." || c == ".." { throw .invalidPath("'\(c)' component") }
            if c.utf8.contains(0) { throw .invalidPath("NUL in component") }
            if c.utf8.contains(UInt8(ascii: "/")) { throw .invalidPath("'/' in component") }
        }
        self.components = components
    }

    /// `absolute` below `root`, matched component by component on exact bytes, never by string prefix: root
    /// `/x/a` does not contain `/x/ab/f`. Case or Unicode-normalization variants of the root don't match either
    /// (they fail closed as `.outsideRoot`).
    public static func confined(_ absolute: String, under root: String) throws(SafePathError) -> RelativePath {
        guard absolute.hasPrefix("/"), root.hasPrefix("/") else { throw .invalidPath("not absolute") }
        let rootParts = root.split(separator: "/", omittingEmptySubsequences: true)
        let parts = absolute.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.count > rootParts.count else { throw .outsideRoot }
        for (p, r) in zip(parts, rootParts) where !p.utf8.elementsEqual(r.utf8) {
            throw .outsideRoot
        }
        return try RelativePath(components: parts.dropFirst(rootParts.count).map(String.init))
    }

    public var leaf: String { components[components.count - 1] }
    public var description: String { components.joined(separator: "/") }
}

/// A scan or permitted root opened once; every open below it is fd-relative and refuses symlinks and escapes.
///
/// Kernel mode (both launch probes pass): one `openat(root, rel, O_RESOLVE_BENEATH | O_NOFOLLOW_ANY)`. Otherwise a
/// per-component walk with `O_NOFOLLOW` (`O_DIRECTORY` for intermediates). An identity chain always uses the walk, so
/// every ancestor's (dev, ino) comes from the descriptor actually opened.
public final class TrustedRoot: Sendable {
    public enum Resolution: Sendable {
        /// Kernel resolution when the probes pass, else the walk.
        case automatic
        /// Always walk (tests; also what `automatic` falls back to).
        case componentWalk
    }

    /// As given by the caller.
    public let path: String
    /// `realpath` of `path`: the root is trusted input, so symlinks in its own spelling (`/var` → `/private/var`)
    /// are resolved once; nothing below it is.
    public let canonicalPath: String
    public let identity: FileIdentity
    /// Live identities from `/` down to the root itself, opened component by component without following symlinks.
    public let chain: [FileIdentity]
    public let usesKernelResolution: Bool
    private let fd: FileDescriptor

    public convenience init(path: String, resolution: Resolution = .automatic) throws(SafePathError) {
        try self.init(path: path, resolution: resolution, probePassed: Self.kernelResolutionAvailable)
    }

    /// `probePassed`: test seam for the launch probe result (a failed probe must fall back to the walk).
    init(path: String, resolution: Resolution, probePassed: Bool) throws(SafePathError) {
        // Spelling is checked before `realpath`, which would silently normalize `..`, `.` and `//`.
        guard path.hasPrefix("/") else { throw .invalidPath("not absolute") }
        if path != "/" { _ = try RelativePath(validating: String(path.dropFirst())) }
        guard let resolved = Darwin.realpath(path, nil) else {
            throw .posix(op: "realpath \(path)", errno: Darwin.errno)
        }
        let canonical = String(cString: resolved)
        free(resolved)

        var current = try FileDescriptor.open(at: AT_FDCWD, "/", flags: O_RDONLY | O_DIRECTORY)
        var chain = [try current.identity()]
        for component in canonical.split(separator: "/") {
            let next = try FileDescriptor.open(at: current.rawValue, String(component),
                                               flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            chain.append(try next.identity())
            current = next
        }
        self.path = path
        self.canonicalPath = canonical
        self.identity = chain[chain.count - 1]
        self.chain = chain
        self.usesKernelResolution = resolution == .automatic && probePassed
        self.fd = current
    }

    /// Both probes passed once in this process: `..` beneath a dir fails with `ENOTCAPABLE` and a mid-path symlink
    /// fails with `ELOOP`. The headers carry no availability for these flags, and an older kernel may ignore the
    /// bits silently (`O_RESOLVE_BENEATH` shares FMARK's value), so any probe failure means "walk".
    public static let kernelResolutionAvailable: Bool = probeKernelResolution()

    /// Borrow the root descriptor (never close it).
    public func withDescriptor<R, E: Error>(_ body: (Int32) throws(E) -> R) throws(E) -> R {
        try body(fd.rawValue)
    }

    /// `absolute` relative to this root, accepting either the given or the canonical spelling of the root.
    public func relativePath(of absolute: String) throws(SafePathError) -> RelativePath {
        do {
            return try RelativePath.confined(absolute, under: path)
        } catch .outsideRoot {
            return try RelativePath.confined(absolute, under: canonicalPath)
        }
    }

    /// Opens `rel` below the root with `flags` (+ `O_CLOEXEC`), never through a symlink.
    public func open(_ rel: RelativePath, flags: Int32) throws(SafePathError) -> FileDescriptor {
        if usesKernelResolution {
            return try FileDescriptor.open(at: fd.rawValue, rel.description,
                                           flags: flags | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY)
        }
        var chain: [FileIdentity]? = nil
        return try walk(rel, finalFlags: flags, chain: &chain)
    }

    /// An opened target plus the identities of every directory opened below the root and the target itself
    /// (prefix with `TrustedRoot.chain` for the full chain from `/`).
    public struct Opened: ~Copyable, Sendable {
        public let fd: FileDescriptor
        public let chain: [FileIdentity]
    }

    /// The directory holding a target's last component, for (dir fd, leaf name) operations such as `renameatx_np`
    /// and `fstatat`. `chain` covers the directories opened below the root (empty when the parent is the root).
    public struct OpenedParent: ~Copyable, Sendable {
        public let parent: FileDescriptor
        public let leaf: String
        public let chain: [FileIdentity]
    }

    public func openWithChain(_ rel: RelativePath, flags: Int32) throws(SafePathError) -> Opened {
        var chain: [FileIdentity]? = []
        let opened = try walk(rel, finalFlags: flags, chain: &chain)
        return Opened(fd: opened, chain: chain ?? [])
    }

    public func openParent(_ rel: RelativePath) throws(SafePathError) -> OpenedParent {
        guard rel.components.count > 1 else { return OpenedParent(parent: try fd.duplicate(), leaf: rel.leaf, chain: []) }
        let parentRel = try RelativePath(components: Array(rel.components.dropLast()))
        var chain: [FileIdentity]? = []
        let parent = try walk(parentRel, finalFlags: O_RDONLY | O_DIRECTORY, chain: &chain)
        return OpenedParent(parent: parent, leaf: rel.leaf, chain: chain ?? [])
    }

    private func walk(_ rel: RelativePath, finalFlags: Int32,
                      chain: inout [FileIdentity]?) throws(SafePathError) -> FileDescriptor {
        var current = try fd.duplicate()
        for (i, component) in rel.components.enumerated() {
            let last = i == rel.components.count - 1
            let flags = last ? finalFlags | O_NOFOLLOW : O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            let next = try FileDescriptor.open(at: current.rawValue, component, flags: flags)
            if chain != nil { chain?.append(try next.identity()) }
            current = next
        }
        return current
    }

    private static func probeKernelResolution() -> Bool {
        let template = NSTemporaryDirectory() + "dev.telltale.safepath-probe.XXXXXX"
        var buffer = Array(template.utf8CString)
        guard let dir = mkdtemp(&buffer) else {
            DiskTools.log.error("SafePath probe: mkdtemp failed, errno \(Darwin.errno); using component walk")
            return false
        }
        let dirPath = String(cString: dir)
        defer {
            // Leftovers only cost a few bytes in the temp dir; log so a failure is visible, nothing else to do.
            let unlinkPath: (String) -> Int32 = { unlink($0) }
            let rmdirPath: (String) -> Int32 = { rmdir($0) }
            let steps = [("d/f", unlinkPath), ("l", unlinkPath), ("d", rmdirPath), ("", rmdirPath)]
            for (name, remove) in steps where remove(dirPath + "/" + name) != 0 && Darwin.errno != ENOENT {
                DiskTools.log.error("SafePath probe cleanup: \(name) errno \(Darwin.errno)")
            }
        }
        guard mkdir(dirPath + "/d", 0o700) == 0, symlink("d", dirPath + "/l") == 0 else {
            DiskTools.log.error("SafePath probe: setup failed, errno \(Darwin.errno); using component walk")
            return false
        }
        let created = Darwin.open(dirPath + "/d/f", O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        guard created >= 0 else {
            DiskTools.log.error("SafePath probe: setup failed, errno \(Darwin.errno); using component walk")
            return false
        }
        close(created)

        let root = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return false }
        defer { close(root) }

        func opens(_ rel: String, _ flags: Int32) -> (ok: Bool, errno: Int32) {
            let f = Darwin.openat(root, rel, O_RDONLY | O_CLOEXEC | flags)
            let e = Darwin.errno
            if f >= 0 { close(f) }
            return (f >= 0, e)
        }
        let inside = opens("d/f", O_RESOLVE_BENEATH | O_NOFOLLOW_ANY)
        let escape = opens("..", O_RESOLVE_BENEATH)
        let throughLink = opens("l/f", O_NOFOLLOW_ANY)
        let available = inside.ok && !escape.ok && escape.errno == ENOTCAPABLE
            && !throughLink.ok && throughLink.errno == ELOOP
        if !available {
            DiskTools.log.notice("SafePath probe: kernel resolution unavailable; using component walk")
        }
        return available
    }
}
