import CoreServices
import Darwin
import Foundation
import MonitorModel
import Synchronization

/// Parallel directory walker (spec §5). One `scan` at a time: starting another cancels the running one.
///
/// Named `Scanner` as the plan has it; in files that also import Foundation, spell it `MonitorDiskTools.Scanner`.
public final class Scanner: Sendable {
    private let lister: any DirectoryLister
    private let threads: Int
    private let home: String
    private let current = Mutex<ScanRun?>(nil)

    private let access: ScanAccessPolicy?
    private let progressInterval: Duration

    /// `home` anchors the `~/Library/*` rules. `access` nil = probe Full Disk Access at the start of each scan
    /// (tests inject a policy). A scan blocked inside `openat` (a consent prompt) cannot be interrupted: cancel
    /// takes effect when that call returns, which is why the policy keeps the walk away from prompting folders.
    public init(lister: any DirectoryLister, threads: Int, home: String, access: ScanAccessPolicy? = nil,
                progressInterval: Duration = .milliseconds(100)) {
        self.lister = lister
        self.threads = max(1, threads)
        self.home = home
        self.access = access
        self.progressInterval = progressInterval
    }

    /// Entries the current (or last) scan has enumerated, kept and folded alike.
    public var enumeratedEntries: Int { current.withLock { $0?.enumeratedEntries ?? 0 } }

    /// Spikes §6: 16 threads gain nothing over 8; fewer on small machines.
    public static func defaultThreadCount() -> Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 else {
            return min(8, ProcessInfo.processInfo.activeProcessorCount)
        }
        return min(8, Int(cores))
    }

    /// Events: `.progress` ≤ 10 Hz, `.partial` ~3 Hz, then exactly one `.finished` or `.failed`, then the stream
    /// ends. `willUnmount` carries mount points about to unmount; one holding the root cancels with
    /// `.failed(.volumeRemoved)`. The caller decides what to cache: only `.finished` trees are complete.
    public func scan(root: ScanRoot, willUnmount: AsyncStream<String> = AsyncStream { $0.finish() })
        -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self, bufferingPolicy: .bufferingNewest(16))
        // Taken before the walk, so anything changing during it counts as "changed since scan".
        let lastEventId = FSEventsGetCurrentEventId()
        // Access policy first, before anything below the root is opened.
        let policy = access ?? .detect(home: home)
        let rules = WalkRules(root: root, home: home)
        if rules.blocks([], access: policy) {
            // The root itself is a closed location (or inside one): not even acquired, reported as an unreadable
            // root node with no contents.
            var builder = StorageTreeBuilder(root: root, dev: 0, volumeUUID: nil)
            builder.setRestricted(0)
            continuation.yield(.finished(builder.finalize(scanDate: Date(), lastEventId: lastEventId)))
            continuation.finish()
            return stream
        }
        let info: ScanRootInfo
        do {
            info = try lister.rootInfo()
        } catch {
            DiskTools.log.error("scan root \(root.path) unreadable: \(error.op) errno \(error.errno)")
            continuation.yield(.failed(.rootUnreadable(root.path)))
            continuation.finish()
            return stream
        }

        let run = ScanRun(root: root, info: info, lastEventId: lastEventId, lister: lister,
                          rules: rules, access: policy,
                          progressInterval: progressInterval, threads: threads, continuation: continuation)
        current.withLock { previous in
            previous?.fail(.cancelled)
            previous = run
        }
        continuation.onTermination = { _ in run.fail(.cancelled) }

        let rootSpellings = [root.path, Self.canonical(root.path)]
        let unmountWatcher = Task.detached(priority: .utility) {
            for await mountPath in willUnmount
            where rootSpellings.contains(where: { VolumeWatch.unmountAffects(mountPath: mountPath, rootPath: $0) }) {
                run.fail(.volumeRemoved)
                return
            }
        }
        run.onFinish { unmountWatcher.cancel() }
        if let revoke = VolumeWatch.watchRevocation(path: root.path, onRevoke: { run.fail(.volumeRemoved) }) {
            run.onFinish { revoke.cancel() }
        }
        run.start()
        return stream
    }

    /// Cancels the running scan: its stream yields `.failed(.cancelled)` and ends at once. Workers stuck in a syscall
    /// leave later; their results are dropped.
    public func cancel() {
        current.withLock { $0?.fail(.cancelled) }
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
