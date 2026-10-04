import Darwin
import Foundation
import MonitorModel

/// A cleanup target opened below a `TrustedRoot`: its parent directory (for fd-relative renames) and the live
/// identities from `/` down to the target, collected from the descriptors actually opened.
struct LiveTarget: ~Copyable, Sendable {
    let parent: FileDescriptor
    let parentIdentity: FileIdentity
    let leaf: String
    let identity: FileIdentity
    /// `/` … root … parent … target (last element = `identity`).
    let chain: [FileIdentity]
    /// The components that were walked: the root's canonical path plus the target's relative path. Symlink-free.
    let components: [String]

    /// `absolutePath` must be below `root` by spelling (component-wise, exact bytes) and is then opened without
    /// following any symlink. A symlink as the last component is the target itself (it is not followed).
    static func open(root: TrustedRoot, absolutePath: String) throws(SafePathError) -> LiveTarget {
        let rel = try root.relativePath(of: absolutePath)
        let opened = try root.openParent(rel)
        let identity = try opened.parent.identity(of: opened.leaf)
        let parentChain = root.chain + opened.chain
        let rootComponents = root.canonicalPath.split(separator: "/").map(String.init)
        return LiveTarget(parent: opened.parent, parentIdentity: parentChain[parentChain.count - 1],
                          leaf: opened.leaf, identity: identity, chain: parentChain + [identity],
                          components: rootComponents + rel.components)
    }
}

/// Paths a cleanup may never touch. Two independent layers, both applied to every target right before it is moved:
///
/// 1. Identity (dev, ino), from the live filesystem when the run started: case, Unicode-normalization variants,
///    `..` and symlinks all end at the same identities.
/// 2. Spelling of the walked path, compared by component (case-insensitive, Unicode-normalized): catches a
///    protected directory that was deleted and re-created during the run (new inode, same name) and one that did
///    not exist when the run started.
///
/// - Anchors (`/`, `~`, `~/Library` and its children, system dirs, the scan root): a target must not **be or
///   contain** one.
/// - Protected (Keychains, iCloud, Mail, our own data, …): a target must not **be, contain, or be inside** one.
///
/// Built once per run; a path that doesn't exist contributes its existing ancestors only (so it is still
/// "contained" by them).
public struct Denylist: Sendable {
    private let anchorBlock: Set<FileIdentity>
    private let protectedBlock: Set<FileIdentity>
    private let protectedIdentities: Set<FileIdentity>
    private let anchorRules: [[String]]
    private let protectedRules: [[String]]
    /// Every direct child of these (`~/Library`, also those created after the run started) is an anchor.
    private let childAnchorParents: [[String]]
    /// A chain could not be established (unreadable ancestor): nothing can be verified, so everything is refused.
    private let unverifiable: Bool
    let anchorPaths: [String]
    let protectedPaths: [String]

    static let systemAnchors = ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/private",
                                "/opt/homebrew", "/usr/local"]

    public static func build(home: String, scanRoot: String, dataDirectories: [String]) -> Denylist {
        var anchors = systemAnchors + [home, home + "/Library", scanRoot]
        var failed = false
        switch libraryChildren(of: home + "/Library") {
        case let .success(children): anchors += children.map { home + "/Library/" + $0 }
        case .failure: failed = true
        }
        let protected = [
            "Keychains", "Mobile Documents", "CloudStorage", "Mail", "Application Support/MobileSync",
            "Application Support/dev.warden", "Application Support/dev.telltale", "Caches/dev.telltale-dev",
        ].map { home + "/Library/" + $0 } + dataDirectories

        var anchorBlock = Set<FileIdentity>()
        var protectedBlock = Set<FileIdentity>()
        var protectedIdentities = Set<FileIdentity>()
        for path in anchors {
            guard let chain = liveChain(of: path) else { failed = true; continue }
            anchorBlock.formUnion(chain)
            // A symlink anchor (e.g. a link directly under ~/Library): `realpath` skips the link itself, but the link
            // is what a target path can name, so its own inode is anchored too.
            if let link = linkIdentity(path) { anchorBlock.insert(link) }
        }
        for path in protected {
            guard let chain = liveChain(of: path) else { failed = true; continue }
            protectedBlock.formUnion(chain)
            if let last = chain.last, pathExists(path) { protectedIdentities.insert(last) }
            if let link = linkIdentity(path) { protectedIdentities.insert(link); protectedBlock.insert(link) }
        }
        return Denylist(anchorBlock: anchorBlock, protectedBlock: protectedBlock,
                        protectedIdentities: protectedIdentities, unverifiable: failed, anchorPaths: anchors,
                        protectedPaths: protected,
                        anchorRules: anchors.flatMap(rules(for:)), protectedRules: protected.flatMap(rules(for:)),
                        childAnchorParents: rules(for: home + "/Library"))
    }

    private init(anchorBlock: Set<FileIdentity>, protectedBlock: Set<FileIdentity>,
                 protectedIdentities: Set<FileIdentity>, unverifiable: Bool, anchorPaths: [String],
                 protectedPaths: [String], anchorRules: [[String]], protectedRules: [[String]],
                 childAnchorParents: [[String]]) {
        self.anchorBlock = anchorBlock
        self.protectedBlock = protectedBlock
        self.protectedIdentities = protectedIdentities
        self.unverifiable = unverifiable
        self.anchorPaths = anchorPaths
        self.protectedPaths = protectedPaths
        self.anchorRules = anchorRules
        self.protectedRules = protectedRules
        self.childAnchorParents = childAnchorParents
    }

    /// Folding for the spelling layer: Unicode canonical decomposition plus lowercase, so `Mail`, `MAIL` and
    /// NFC/NFD spellings of one name compare equal. It over-matches on case-sensitive volumes, which only errs
    /// toward refusing.
    private static func fold(_ component: String) -> String {
        component.decomposedStringWithCanonicalMapping.lowercased()
    }

    /// Folded components of `path` as given and in its canonical (`realpath`) spelling.
    private static func rules(for path: String) -> [[String]] {
        spellings(of: path).map { $0.split(separator: "/").map { fold(String($0)) } }
    }

    /// Spelling layer: `components` are the walked path components (see `LiveTarget.components`).
    func check(components: [String]) -> DenyReason? {
        let target = components.map(Self.fold)
        for rule in anchorRules where target.count <= rule.count && rule.starts(with: target) { return .anchor }
        for parent in childAnchorParents where target.count == parent.count + 1 && target.starts(with: parent) {
            return .anchor
        }
        for rule in protectedRules where target.count <= rule.count ? rule.starts(with: target) : target.starts(with: rule) {
            return .protected
        }
        return nil
    }

    /// Both layers for an opened target; call immediately before the mutation.
    func check(live: borrowing LiveTarget) -> DenyReason? {
        check(chain: live.chain) ?? check(components: live.components)
    }

    /// `chain` = identities from `/` to the target (last element), e.g. `root.chain + opened.chain + [leaf]`.
    public func check(chain: [FileIdentity]) -> DenyReason? {
        guard !unverifiable, let target = chain.last else { return .unverifiable }
        if anchorBlock.contains(target) { return .anchor }
        if protectedBlock.contains(target) { return .protected }
        // Inside: any ancestor of the target is a protected directory (this also covers a scan root that is
        // itself below one, because the root's chain is part of `chain`).
        if chain.contains(where: protectedIdentities.contains) { return .protected }
        return nil
    }

    /// Opens `target` below `root` and checks its live chain. A target that no longer exists has nothing to deny
    /// (the cleaner reports it as vanished).
    public func check(root: TrustedRoot, target: String) -> DenyReason? {
        do {
            let live = try LiveTarget.open(root: root, absolutePath: target)
            return check(live: live)
        } catch {
            switch CleanFS.skipReason(for: error) {
            case .vanished: return nil
            case let .denied(reason): return reason
            default: return .unverifiable
            }
        }
    }

    /// The same paths as tree nodes, for the UI to disable actions up front. Advisory: a snapshot against this
    /// tree, matched by spelling; the cleaner re-checks live identity for every target.
    public func policy(for tree: StorageTree) -> StoragePolicy {
        func nodes(_ paths: [String], aboveRootIsInside: Bool) -> Set<StorageNodeID> {
            var result = Set<StorageNodeID>()
            for path in paths {
                for spelling in Self.spellings(of: path) {
                    if let node = tree.lookup(path: spelling) {
                        result.insert(node)
                    } else if aboveRootIsInside, (try? RelativePath.confined(tree.root.path, under: spelling)) != nil {
                        // The scan root is below this path, so every node is inside it.
                        result.insert(0)
                    }
                }
            }
            return result
        }
        return StoragePolicy(treeVersion: tree.version, anchors: nodes(anchorPaths, aboveRootIsInside: false),
                             protected: nodes(protectedPaths, aboveRootIsInside: true))
    }

    // MARK: - Live chains

    private static func spellings(of path: String) -> [String] {
        guard let resolved = Darwin.realpath(path, nil) else { return [path] }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        return canonical == path ? [path] : [path, canonical]
    }

    private static func pathExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Identity of `path` itself when it is a symlink (the link's own inode, which `realpath` would skip).
    private static func linkIdentity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return nil }
        return FileIdentity(st)
    }

    private static func libraryChildren(of path: String) -> Result<[String], SafePathError> {
        guard let dir = opendir(path) else {
            let e = Darwin.errno
            // No ~/Library yet: nothing to list.
            return e == ENOENT ? .success([]) : .failure(.posix(op: "opendir \(path)", errno: e))
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingCString: $0) }
            }
            if let name, name != ".", name != ".." { names.append(name) }
        }
        return .success(names)
    }

    /// Identities from `/` down to `path`, or down to its deepest existing ancestor when the tail doesn't exist.
    /// The path is trusted input (our own constants and injected directories), so its symlinks are resolved once
    /// with `realpath`; the identities themselves come from a no-follow walk. nil = chain not establishable.
    static func liveChain(of path: String) -> [FileIdentity]? {
        var existing = path
        while true {
            if let resolved = Darwin.realpath(existing, nil) {
                defer { free(resolved) }
                return walk(String(cString: resolved))
            }
            guard Darwin.errno == ENOENT || Darwin.errno == ENOTDIR, existing != "/" else { return nil }
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
    }

    private static func walk(_ canonical: String) -> [FileIdentity]? {
        guard var current = try? FileDescriptor.open(at: AT_FDCWD, "/", flags: O_RDONLY | O_DIRECTORY) else {
            return nil
        }
        guard var chain = (try? current.identity()).map({ [$0] }) else { return nil }
        let components = canonical.split(separator: "/").map(String.init)
        for (i, component) in components.enumerated() {
            if i == components.count - 1 {
                // The last component is only stat'ed: it may be a file, and opening it would add nothing.
                guard let identity = try? current.identity(of: component) else { return nil }
                chain.append(identity)
                return chain
            }
            guard let next = try? FileDescriptor.open(at: current.rawValue, component,
                                                      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW),
                  let identity = try? next.identity() else { return nil }
            chain.append(identity)
            current = next
        }
        return chain
    }
}
