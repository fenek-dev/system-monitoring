import Darwin
import Foundation
import MonitorModel

public struct InUseReport: Equatable, Sendable {
    public var inUse: Set<Int32>
    public var unknownHolders: Int
}

/// Which cleanup items are held open (running binary, working directory, open file) by a process of this user.
public struct InUseChecker: Sendable {
    private let processes: any ProcessPathSource

    public init(processes: any ProcessPathSource) {
        self.processes = processes
    }

    public func inUse(_ items: [CleanupItem]) -> Set<Int32> {
        check(items).inUse
    }

    public func check(_ items: [CleanupItem]) -> InUseReport {
        let held = processes.snapshot()
        // A held path marks itself and every ancestor directory, so an item matches when it is the held path or a
        // directory above it: whole components only, `/a/bc` never matches a holder of `/a/b/c`.
        var marked = Set<String>()
        for path in held.paths {
            var current = path
            while current.count > 1, marked.insert(current).inserted {
                current = (current as NSString).deletingLastPathComponent
            }
        }
        var result = Set<Int32>()
        for item in items where Self.spellings(of: item.path).contains(where: marked.contains) {
            result.insert(item.id)
        }
        return InUseReport(inUse: result, unknownHolders: held.unknownHolders)
    }

    /// The item path as given and with its parent canonicalized (kernel paths are `/private/var/...`). The leaf is
    /// not resolved: a symlink item is the link itself.
    private static func spellings(of path: String) -> [String] {
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolved = Darwin.realpath(parent, nil) else { return [path] }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        let leaf = (path as NSString).lastPathComponent
        let joined = canonical == "/" ? "/" + leaf : canonical + "/" + leaf
        return joined == path ? [path] : [path, joined]
    }
}
