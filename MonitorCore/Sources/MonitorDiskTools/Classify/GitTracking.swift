import Foundation

/// Whether git tracks any file under a candidate build dir. Fails closed: anything but a clean "no" is "tracked", so
/// a `build/` that holds committed files is never offered.
public protocol GitTracking: Sendable {
    func hasTrackedFiles(project: String, dir: String) -> Bool
}

/// `git -C <project> ls-files -z -- <dir>`, 5 s timeout. Callers check `DevToolProbe.xcodeSelectOK` first: with no
/// developer tools, `/usr/bin/git` is a stub that raises the Command Line Tools install prompt.
public struct LiveGitTracking: GitTracking {
    public static let timeout: TimeInterval = 5

    public init() {}

    public func hasTrackedFiles(project: String, dir: String) -> Bool {
        let prefix = project.hasSuffix("/") ? project : project + "/"
        guard dir.hasPrefix(prefix) else { return true }
        let relative = String(dir.dropFirst(prefix.count))
        do {
            let out = try ProcessRun.run(
                "/usr/bin/git", ["-C", project, "ls-files", "-z", "--", relative],
                // No index refresh: this probe must not write into the repository.
                environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: Self.timeout, outputLimit: 1)
            guard out.status == 0 else {
                DiskTools.log.error("git ls-files exited \(out.status) in \(project, privacy: .public)")
                return true
            }
            return !out.stdout.isEmpty
        } catch {
            DiskTools.log.error("git ls-files failed in \(project, privacy: .public): \(String(describing: error), privacy: .public)")
            return true
        }
    }
}
