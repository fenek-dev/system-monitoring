import Foundation
import MonitorModel
import Observation
import os

@MainActor @Observable
public final class CleanupState {
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    public private(set) var items: [CleanupItem] = []
    public private(set) var checked: Set<Int32> = []
    /// Checked items a process holds open (set by `recheckInUse`); they are unchecked when found.
    public internal(set) var inUse: Set<Int32> = []

    // Footer totals over the checked items; hard links counted over the whole selection.
    public private(set) var selectedBytes: UInt64 = 0
    public private(set) var selectedCount = 0
    /// Shown as "≈" when not `.exact`.
    public private(set) var selectedProvenance: SizeProvenance = .exact
    public private(set) var categoryTotals: [CleanupCategory: CategoryTotal] = [:]
    /// The accumulator could not be built (tree/overlay mismatch, a bug): the footer shows "—".
    public internal(set) var totalsUnavailable = false

    public var category: CleanupCategory = .userCaches
    public var sort = CleanupSort()
    public var expanded: Set<CleanupLineID> = []
    public var showIgnored = false

    public internal(set) var cleanProgress: CleanProgress?
    public internal(set) var skipped: [(item: CleanupItem, reason: SkipReason)] = []
    public internal(set) var lastReport: CleanReport?
    public internal(set) var lastUndo: UndoRecord?

    // Derived state, kept out of observation: views depend on `items`/`checked`/`sort`… and call the accessors.
    @ObservationIgnored private var linkSizes: [Int32: LinkGroupSize] = [:]
    @ObservationIgnored private var global: ReclaimAccumulator?
    @ObservationIgnored private var perCategory: [CleanupCategory: ReclaimAccumulator] = [:]
    /// Bumped on every change of `items` (or of what the rows show); also refreshes the id index.
    @ObservationIgnored private var itemsVersion = 0 {
        didSet { indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) }) }
    }
    @ObservationIgnored private var indexByID: [Int32: Int] = [:]

    private struct LinesKey: Equatable {
        var category: CleanupCategory
        var sort: CleanupSort
        var expanded: Set<CleanupLineID>
        var showIgnored: Bool
        var itemsVersion: Int
    }

    @ObservationIgnored private var linesKey: LinesKey?
    @ObservationIgnored private var linesOutput = CleanupLineBuilder.Output()

    public init() {}

    // MARK: - Rows

    /// Cached per (category, sort, expanded, showIgnored, items): checked state is not part of the key, so a
    /// toggle never rebuilds rows; views read `checkState` per row.
    public func lines() -> [CleanupLine] {
        currentLines().lines
    }

    private func currentLines() -> CleanupLineBuilder.Output {
        let key = LinesKey(category: category, sort: sort, expanded: expanded, showIgnored: showIgnored,
                           itemsVersion: itemsVersion)
        if linesKey != key {
            linesOutput = CleanupLineBuilder.build(items: items, category: category, sort: sort,
                                                   expanded: expanded, showIgnored: showIgnored)
            linesKey = key
        }
        return linesOutput
    }

    public func checkState(_ line: CleanupLineID) -> CheckState {
        switch line {
        case let .item(id):
            return checked.contains(id) ? .on : .off
        case .group:
            let members = currentLines().members[line] ?? []
            let on = members.count(where: { checked.contains($0) })
            if on == 0 { return .off }
            return on == members.count ? .on : .mixed
        }
    }

    public func item(_ id: Int32) -> CleanupItem? {
        indexByID[id].map { items[$0] }
    }

    public func total(for category: CleanupCategory) -> CategoryTotal {
        categoryTotals[category] ?? CategoryTotal()
    }

    public func toggle(_ line: CleanupLineID) {
        switch line {
        case let .item(id):
            guard let item = item(id), item.isCheckable else { return }
            setChecked(id, to: !checked.contains(id))
        case .group:
            let members = currentLines().members[line] ?? []
            let check = checkState(line) != .on
            for id in members { setChecked(id, to: check) }
        }
    }

    // MARK: - Model-side mutations

    /// Replaces the item list. Items whose path was listed before keep their checked state (ids differ between
    /// classification passes of the same tree); new paths get the default.
    func load(_ set: CleanupSet, tree: StorageTree, overlay: StorageTreeOverlay?) {
        let previousPaths = Set(items.map(\.path))
        let previouslyChecked = Set(items.filter { checked.contains($0.id) }.map(\.path))
        items = set.items
        linkSizes = set.linkGroupSizes
        checked = Set(set.items.filter {
            $0.isCheckable && (previousPaths.contains($0.path) ? previouslyChecked.contains($0.path)
                                                               : $0.isCheckedByDefault)
        }.map(\.id))
        inUse.formIntersection(items.map(\.id))
        itemsVersion += 1
        rebuildTotals(tree: tree, overlay: overlay)
    }

    func clear() {
        items = []
        checked = []
        inUse = []
        linkSizes = [:]
        skipped = []
        cleanProgress = nil
        lastReport = nil
        lastUndo = nil
        global = nil
        perCategory = [:]
        categoryTotals = [:]
        selectedBytes = 0
        selectedCount = 0
        selectedProvenance = .exact
        totalsUnavailable = false
        itemsVersion += 1
    }

    /// Drops items (cleaned away). Totals are rebuilt by the caller once the overlay change is in.
    func remove(ids: Set<Int32>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        checked.subtract(ids)
        inUse.subtract(ids)
        itemsVersion += 1
    }

    /// Replaces an item in place (keep-parent partial clean: smaller now, no longer selected).
    func replace(_ item: CleanupItem, checked isChecked: Bool) {
        guard let index = indexByID[item.id] else { return }
        items[index] = item
        if isChecked { checked.insert(item.id) } else { checked.remove(item.id) }
        itemsVersion += 1
    }

    /// Re-adds an item (undo), unchecked.
    func append(_ item: CleanupItem) {
        guard indexByID[item.id] == nil else { return }
        items.append(item)
        itemsVersion += 1
    }

    func setIgnored(_ ignored: Bool, path: String) {
        var changed = false
        for index in items.indices where items[index].path == path && items[index].ignored != ignored {
            items[index].ignored = ignored
            checked.remove(items[index].id)
            changed = true
        }
        if changed { itemsVersion += 1 }
    }

    func uncheck(_ ids: Set<Int32>) {
        checked.subtract(ids)
    }

    /// Fresh accumulators over the current items, overlay and link sizes, re-inserting the surviving checked ids
    /// (the accumulator is immutable over its item list).
    func rebuildTotals(tree: StorageTree, overlay: StorageTreeOverlay?) {
        var counts: [CleanupCategory: CategoryTotal] = [:]
        for item in items where !item.ignored {
            counts[item.category, default: CategoryTotal()].itemCount += 1
            if item.tier == .safe { counts[item.category, default: CategoryTotal()].safeCount += 1 } else {
                counts[item.category, default: CategoryTotal()].reviewCount += 1
            }
        }
        do {
            var all = try ReclaimAccumulator(items: items, tree: tree, overlay: overlay, linkSizes: linkSizes)
            var accumulators: [CleanupCategory: ReclaimAccumulator] = [:]
            for category in CleanupCategory.allCases {
                let members = items.filter { $0.category == category }
                var acc = try ReclaimAccumulator(items: members, tree: tree, overlay: overlay, linkSizes: linkSizes)
                let eligible = members.filter(\.isCheckable)
                for item in eligible { acc.insert(item.id) }
                var total = counts[category] ?? CategoryTotal()
                total.bytes = acc.bytes
                total.provenance = acc.provenance
                for item in eligible where !checked.contains(item.id) { acc.remove(item.id) }
                total.selectedBytes = acc.bytes
                counts[category] = total
                accumulators[category] = acc
            }
            for id in checked { all.insert(id) }
            global = all
            perCategory = accumulators
            totalsUnavailable = false
            publishSelection()
            categoryTotals = counts
        } catch {
            Self.log.fault("totals unavailable: \(String(describing: error), privacy: .public)")
            global = nil
            perCategory = [:]
            categoryTotals = counts
            totalsUnavailable = true
            selectedBytes = 0
            selectedCount = checked.count
            selectedProvenance = .exact
        }
    }

    private func setChecked(_ id: Int32, to on: Bool) {
        guard let item = item(id), checked.contains(id) != on else { return }
        if on {
            checked.insert(id)
            global?.insert(id)
            perCategory[item.category]?.insert(id)
        } else {
            checked.remove(id)
            global?.remove(id)
            perCategory[item.category]?.remove(id)
        }
        publishSelection()
        categoryTotals[item.category, default: CategoryTotal()].selectedBytes = perCategory[item.category]?.bytes ?? 0
    }

    private func publishSelection() {
        guard let global else { return }
        selectedBytes = global.bytes
        selectedCount = global.count
        selectedProvenance = global.provenance
    }
}
