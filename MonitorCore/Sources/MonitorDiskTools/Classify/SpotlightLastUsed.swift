import CoreServices
import Foundation

/// `kMDItemLastUsedDate` of large files under a root, from one scoped Spotlight query (spec §6.4). Most files lack
/// the attribute, so the query asks only for items that have it; the classifier takes the max with mtime/addedTime.
public enum SpotlightLastUsed {
    /// Synchronous: blocks the caller's queue for the query (~0.2-0.35 s measured). Empty (and logged) on failure:
    /// the classifier then ages files by mtime / addedTime alone, so a file only Spotlight knew was opened may be
    /// offered as Large & Old (Review tier, Trash is undoable).
    public static func query(root: String, minBytes: UInt64) -> [String: Date] {
        let predicate = "kMDItemFSSize > \(minBytes) && kMDItemLastUsedDate == *"
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else {
            DiskTools.log.error("spotlight: MDQueryCreate failed")
            return [:]
        }
        MDQuerySetSearchScope(query, [root] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            DiskTools.log.error("spotlight: MDQueryExecute failed for \(root, privacy: .public)")
            return [:]
        }
        var result: [String: Date] = [:]
        for index in 0 ..< MDQueryGetResultCount(query) {
            // Value-list attributes come back nil for `kMDItemPath`; the predicate keeps the result set to the few
            // files that have a last-used date, so reading both from the item is cheap.
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            result[path] = used
        }
        return result
    }
}
