import Foundation
import MonitorModel

public enum CleanupLineID: Hashable, Sendable {
    /// Per-app group inside one category.
    case group(CleanupCategory, bundleID: String)
    case item(Int32)
}

public enum CheckState: Equatable, Sendable {
    case off, on, mixed
}

public struct CleanupSort: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case size, name, lastUsed
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key = .size, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }
}

public struct CleanupLine: Identifiable, Equatable, Sendable {
    public var id: CleanupLineID
    /// 0 = top level, 1 = child of an expanded group.
    public var depth: Int
    public var title: String
    public var bytes: UInt64
    public var provenance: SizeProvenance
    /// Item rows only.
    public var item: CleanupItem?
    /// Group rows only.
    public var owner: OwnerApp?
    public var childCount: Int
}

public struct CategoryTotal: Equatable, Sendable {
    /// Everything eligible in the category (not ignored, not info-only).
    public var bytes: UInt64 = 0
    public var provenance: SizeProvenance = .exact
    public var selectedBytes: UInt64 = 0
    /// Non-ignored items.
    public var itemCount = 0
    public var safeCount = 0
    public var reviewCount = 0
}

public struct CleanProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case detaching, freeing
    }

    public var total: Int
    public var processed: Int
    public var phase: Phase
}

extension CleanupItem {
    /// What the row shows: private bytes once known, else allocated.
    var displayBytes: UInt64 { privateBytesExcludingLinks ?? allocBytes }
    var isCheckable: Bool { !ignored && mode != .none }
    /// Ticked when a scan first shows the item.
    var isCheckedByDefault: Bool { isCheckable && tier == .safe && !runningApp }
}

/// Builds the visible rows of one category. The classifier leaves `parentID` nil, so per-app groups are formed
/// here: two or more visible items of the same owning app.
enum CleanupLineBuilder {
    struct Output {
        var lines: [CleanupLine] = []
        /// Checkable item ids under each group row, for its tri-state checkbox.
        var members: [CleanupLineID: [Int32]] = [:]
    }

    /// Everything the order depends on; ties fall through name, item id, group key so equal sizes never reshuffle.
    private struct SortKey {
        var bytes: UInt64
        var name: String
        var date: Date?
        var itemID: Int32
        var groupKey: String

        func precedes(_ other: SortKey, _ sort: CleanupSort) -> Bool {
            let primary: ComparisonResult = switch sort.key {
            case .size: Self.compare(bytes, other.bytes)
            case .name: name.caseInsensitiveCompare(other.name)
            case .lastUsed: Self.compare(date ?? .distantPast, other.date ?? .distantPast)
            }
            if primary != .orderedSame { return (primary == .orderedAscending) == sort.ascending }
            let byName = name.caseInsensitiveCompare(other.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            if itemID != other.itemID { return itemID < other.itemID }
            return groupKey < other.groupKey
        }

        private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
    }

    private struct Row {
        var line: CleanupLine
        var children: [CleanupLine] = []
        var key: SortKey
    }

    static func build(items: [CleanupItem], category: CleanupCategory, sort: CleanupSort, expanded: Set<CleanupLineID>,
                      showIgnored: Bool) -> Output {
        let visible = items.filter { $0.category == category && (showIgnored || !$0.ignored) }
        var byOwner: [String: [CleanupItem]] = [:]
        for item in visible {
            if let bundle = item.owner?.bundleID { byOwner[bundle, default: []].append(item) }
        }

        var rows: [Row] = []
        var out = Output()
        for item in visible where byOwner[item.owner?.bundleID ?? ""].map({ $0.count < 2 }) ?? true {
            rows.append(Row(line: itemLine(item, depth: 0), key: key(item)))
        }
        for (bundle, group) in byOwner where group.count >= 2 {
            let id = CleanupLineID.group(category, bundleID: bundle)
            let owner = group[0].owner
            let ordered = group.sorted { key($0).precedes(key($1), sort) }
            let title = owner?.name ?? bundle
            let line = CleanupLine(
                id: id, depth: 0, title: title, bytes: group.reduce(0) { $0 + $1.displayBytes },
                provenance: group.map(\.sizeProvenance).max() ?? .exact, item: nil, owner: owner,
                childCount: group.count)
            out.members[id] = group.filter(\.isCheckable).map(\.id)
            rows.append(Row(line: line, children: ordered.map { itemLine($0, depth: 1) },
                            key: SortKey(bytes: line.bytes, name: title, date: group.compactMap(\.lastUsed).max(),
                                         itemID: Int32.min, groupKey: bundle)))
        }
        rows.sort { $0.key.precedes($1.key, sort) }
        for row in rows {
            out.lines.append(row.line)
            if expanded.contains(row.line.id) { out.lines.append(contentsOf: row.children) }
        }
        return out
    }

    private static func key(_ item: CleanupItem) -> SortKey {
        SortKey(bytes: item.displayBytes, name: item.name, date: item.lastUsed, itemID: item.id, groupKey: "")
    }

    private static func itemLine(_ item: CleanupItem, depth: Int) -> CleanupLine {
        CleanupLine(id: .item(item.id), depth: depth, title: item.name, bytes: item.displayBytes,
                    provenance: item.sizeProvenance, item: item, owner: nil, childCount: 0)
    }
}
