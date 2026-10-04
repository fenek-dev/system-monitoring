import CoreServices
import Foundation
import Synchronization

/// `kMDItemLastUsedDate` of large files under a root, from one scoped Spotlight query (spec §6.4). Most files lack
/// the attribute, so the query asks only for items that have it; the classifier takes the max with mtime/addedTime.
public enum SpotlightLastUsed {
    private final class Shared: Sendable {
        /// Address of the running query (`MDQuery` is not Sendable); cleared under the lock before the query dies.
        let query = Mutex<Int?>(nil)
        let result = Mutex<[String: Date]>([:])
    }

    /// Blocks the caller for at most `deadline` seconds (query ~0.2-0.35 s measured). On timeout the query is
    /// stopped, the failure logged, and whatever was read so far returned. On failure the result is empty: the
    /// classifier then ages files by mtime / addedTime alone, so a file only Spotlight knew was opened may be offered
    /// as Large & Old (Review tier, Trash is undoable).
    public static func query(root: String, minBytes: UInt64, deadline: TimeInterval = 10) -> [String: Date] {
        let shared = Shared()
        let finished = DispatchSemaphore(value: 0)
        // The synchronous query runs on its own thread so the deadline can stop it from here.
        DispatchQueue.global(qos: .utility).async {
            run(root: root, minBytes: minBytes, shared: shared)
            finished.signal()
        }
        if finished.wait(timeout: .now() + deadline) == .timedOut {
            DiskTools.log.error("spotlight: query over \(root, privacy: .public) exceeded \(deadline)s, stopping")
            shared.query.withLock { address in
                if let address, let pointer = UnsafeRawPointer(bitPattern: address) {
                    MDQueryStop(Unmanaged<MDQuery>.fromOpaque(pointer).takeUnretainedValue())
                }
            }
            _ = finished.wait(timeout: .now() + 2)
        }
        return shared.result.withLock { $0 }
    }

    private static func run(root: String, minBytes: UInt64, shared: Shared) {
        let predicate = "kMDItemFSSize > \(minBytes) && kMDItemLastUsedDate == *"
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else {
            DiskTools.log.error("spotlight: MDQueryCreate failed")
            return
        }
        MDQuerySetSearchScope(query, [root] as CFArray, 0)
        shared.query.withLock { $0 = Int(bitPattern: Unmanaged.passUnretained(query).toOpaque()) }
        defer { shared.query.withLock { $0 = nil } }
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
            shared.result.withLock { $0[path] = used }
        }
    }
}
