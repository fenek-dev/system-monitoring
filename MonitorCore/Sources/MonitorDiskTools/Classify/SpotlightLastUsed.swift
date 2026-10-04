import CoreServices
import Foundation
import Synchronization

/// `kMDItemLastUsedDate` of large files under a root, from one scoped Spotlight query (spec §6.4). Most files lack
/// the attribute, so the query asks only for items that have it; the classifier takes the max with mtime/addedTime.
public enum SpotlightLastUsed {
    /// What a running query shares with the thread waiting on it: partial results and a way to cancel.
    final class Shared: Sendable {
        private let stopper = Mutex<(@Sendable () -> Void)?>(nil)
        private let found = Mutex<[String: Date]>([:])

        func setStop(_ stop: (@Sendable () -> Void)?) { stopper.withLock { $0 = stop } }
        /// Runs `stop` under the lock, so a query clearing its stopper cannot die while it is being stopped.
        func stop() { stopper.withLock { $0?() } }
        func record(_ path: String, _ date: Date) { found.withLock { $0[path] = date } }
        var results: [String: Date] { found.withLock { $0 } }
    }

    /// Blocks the caller for at most `deadline` seconds (query ~0.2-0.35 s measured). On timeout the query is
    /// stopped, the failure logged, and whatever was read so far returned. On failure the result is empty: the
    /// classifier then ages files by mtime / addedTime alone, so a file only Spotlight knew was opened may be offered
    /// as Large & Old (Review tier, Trash is undoable).
    public static func query(root: String, minBytes: UInt64, deadline: TimeInterval = 10) -> [String: Date] {
        bounded(deadline: deadline) { run(root: root, minBytes: minBytes, shared: $0) }
    }

    /// Runs `work` on a worker thread and cancels it through `Shared.stop` once `deadline` passes.
    static func bounded(deadline: TimeInterval, work: @escaping @Sendable (Shared) -> Void) -> [String: Date] {
        let shared = Shared()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            work(shared)
            finished.signal()
        }
        if finished.wait(timeout: .now() + deadline) == .timedOut {
            DiskTools.log.error("spotlight: query exceeded \(deadline)s, stopping")
            shared.stop()
            _ = finished.wait(timeout: .now() + 2)
        }
        return shared.results
    }

    private static func run(root: String, minBytes: UInt64, shared: Shared) {
        let predicate = "kMDItemFSSize > \(minBytes) && kMDItemLastUsedDate == *"
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else {
            DiskTools.log.error("spotlight: MDQueryCreate failed")
            return
        }
        MDQuerySetSearchScope(query, [root] as CFArray, 0)
        // `MDQuery` is not Sendable: the stopper carries its address and is cleared before the query is released.
        let address = Int(bitPattern: Unmanaged.passUnretained(query).toOpaque())
        shared.setStop {
            if let pointer = UnsafeRawPointer(bitPattern: address) {
                MDQueryStop(Unmanaged<MDQuery>.fromOpaque(pointer).takeUnretainedValue())
            }
        }
        defer { shared.setStop(nil) }
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            DiskTools.log.error("spotlight: MDQueryExecute failed for \(root, privacy: .public)")
            return
        }
        for index in 0 ..< MDQueryGetResultCount(query) {
            // Value-list attributes come back nil for `kMDItemPath`; the predicate keeps the result set to the few
            // files that have a last-used date, so reading both from the item is cheap.
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            shared.record(path, used)
        }
    }
}
