import AppKit
import Darwin
import MonitorModel

/// One Telltale per data directory (final review A-M1 ruling). The first instance holds an exclusive `flock` on
/// `<dataDir>/.instance.lock` for its lifetime; the kernel releases it on exit or crash, so a stale file never
/// blocks a launch. A second launch on the same data dir asks the running instance to open its dashboard
/// (`InstanceActivation`) and exits before it builds a runtime (no second status item, sampler or store writer).
/// Other data dirs (dev worktrees via `TELLTALE_DATA_DIR`) run side by side.
public final class InstanceLock: Sendable {
    public enum Outcome: Sendable {
        case acquired(InstanceLock)
        /// Another live process holds the lock.
        case heldByAnotherInstance
        /// The lock file can't be opened (e.g. read-only dir): launch anyway, don't block the user.
        case unavailable(String)
    }

    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    public static func lockURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(".instance.lock", isDirectory: false)
    }

    public static func acquire(dataDirectory: URL) -> Outcome {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let fd = open(lockURL(dataDirectory: dataDirectory).path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            return err == EWOULDBLOCK ? .heldByAnotherInstance : .unavailable(String(cString: strerror(err)))
        }
        return .acquired(InstanceLock(fd: fd))
    }
}

/// "Open your dashboard" from a second launch to the running instance: a distributed notification whose object is
/// the data dir path (only the instance on that dir answers), optionally naming a page (`--open-dashboard <page>`).
public enum InstanceActivation {
    public static let name = Notification.Name("dev.telltale.instance.activate")
    static let pageKey = "page"

    static func key(_ dataDirectory: URL) -> String { dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path }

    /// Second instance: ask the running one to show its dashboard and hand it activation (macOS 14 cooperative
    /// activation), then the caller exits.
    @MainActor public static func post(dataDirectory: URL, page: DashboardPage?) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: key(dataDirectory), userInfo: page.map { [pageKey: $0.rawValue] }, deliverImmediately: true)
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id) where other.processIdentifier != me {
            NSApp.yieldActivation(to: other)
        }
    }

    /// Running instance: `handler(page)` on the main actor for each activation request on `dataDirectory`.
    /// Keep the returned token; pass it to `DistributedNotificationCenter.default().removeObserver` to stop.
    public static func observe(dataDirectory: URL,
                               handler: @escaping @MainActor @Sendable (DashboardPage?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name, object: key(dataDirectory),
                                                            queue: .main) { note in
            let page = (note.userInfo?[pageKey] as? String).flatMap(DashboardPage.init(rawValue:))
            MainActor.assumeIsolated { handler(page) }
        }
    }
}
