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

    /// The item path as given plus its canonical form: kernel paths are `/private/var/...` with the on-disk case
    /// (the filesystem is usually case-insensitive, so the item may be spelled `~/library/caches/x`). A non-symlink
    /// leaf is resolved with `realpath` (case included); a symlink leaf is the link itself, so only its parent is.
    private static func spellings(of path: String) -> [String] {
        var st = stat()
        let isLink = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
        let canonical: String?
        if isLink {
            let parent = (path as NSString).deletingLastPathComponent
            canonical = realpath(parent).map { ($0 == "/" ? "" : $0) + "/" + (path as NSString).lastPathComponent }
        } else {
            canonical = realpath(path)
        }
        guard let canonical, canonical != path else { return [path] }
        return [path, canonical]
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
