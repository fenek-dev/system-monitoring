import Foundation
import MonitorModel
import Observation
import os

/// All state of the Storage page, fed by `StorageActions` streams. No disk access: scans and cleans run in the
/// engine, this model only applies their events. Sub-objects are observed separately so a progress tick, a hover
/// or a checkbox toggle re-renders only the views that read that object.
@MainActor @Observable
public final class StorageModel {
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    public enum Phase: Equatable, Sendable {
        case idle
        case loadingCache
        case scanning(hasPrevious: Bool)
        case ready
        case failed(ScanFailure)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var summary: StorageSummary?
    /// nil until asked.
    public private(set) var hasFullDiskAccess: Bool?
    public private(set) var availableRoots: [ScanRoot] = []
    public private(set) var policy: StoragePolicy = .none
    public private(set) var root: ScanRoot
    /// Set by the page from its settings (this module cannot import them).
    public var classifyOptions: ClassifyOptions

    public let progress = ScanProgressState()
    public let spaceMap = SpaceMapState()
    public let cleanup = CleanupState()
    public let hover = HoverState()

    @ObservationIgnored private let actions: StorageActions
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Bumped by window close and root change: results of work started before are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?
    @ObservationIgnored private(set) var cleanTask: Task<Void, Never>?
    /// A tree from a finished scan (or the cache) is on screen, as opposed to a partial snapshot.
    @ObservationIgnored private var hasFinalTree = false
    /// Latest classification without its items (trash bytes, link sizes) for the summary.
    @ObservationIgnored private var setMeta: CleanupSet?

    private enum Run { case clean, undo, emptyTrash }

    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var runItems: [Int32: CleanupItem] = [:]
    /// Ids that were rows in the list when the last clean started; only those return to it on undo.
    @ObservationIgnored private var listedAtStart: Set<Int32> = []
    /// Items of the last clean, for undo (the overlay needs their node, bytes and path).
    @ObservationIgnored private var lastCleaned: [Int32: CleanupItem] = [:]
    @ObservationIgnored private var nextTrashItemID: Int32 = -1
    /// Bumped when a scan starts: a cache load requested before it must not replace what the scan shows.
    @ObservationIgnored private var cacheEpoch = 0
    /// Totals, hidden rows and summary are rebuilt once per burst of clean events, not once per event.
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChanges: [PendingChange] = []
    /// Rows of committed items, taken out of the list at flush: removing one by one is O(rows) per event.
    @ObservationIgnored private var pendingRemoved: Set<Int32> = []
    @ObservationIgnored private var pendingUnchecked: Set<Int32> = []
    /// A classification that arrived during a clean: its ids would not match the run's items.
    @ObservationIgnored private var pendingClassified: CleanupSet?
    /// Rows hidden because their node is gone (e.g. a Space Map trash of a parent folder); back on undo.
    @ObservationIgnored private var prunedItems: [Int32: CleanupItem] = [:]
    /// Cleaned items without a tree node (simulators), which a later classification would list again.
    @ObservationIgnored private var cleanedNodeless: Set<String> = []

    private static let flushDelay = Duration.milliseconds(50)

    public enum BusyReason: Equatable, Sendable {
        case scanning, cleaning
    }

    /// Scans and cleans exclude each other: a clean's outcomes are bound to the tree it started on.
    public var busyReason: BusyReason? {
        let progress = cleanup.cleanProgress
        if progress != nil || cleanTask != nil { return .cleaning }
        if case .scanning = phase { return .scanning }
        return nil
    }

    public var canScan: Bool { busyReason != .cleaning }
    public var canClean: Bool { busyReason == nil && phase != .loadingCache && spaceMap.tree != nil }

    public init(actions: StorageActions, home: String = NSHomeDirectory(),
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.actions = actions
        self.now = now
        root = .home(home)
        classifyOptions = ClassifyOptions(now: now())
    }

    /// Snapshot renders and fixtures cannot await `pageDidAppear`; this sets what it would have found.
    public func seedAccess(hasFullDiskAccess: Bool?, availableRoots: [ScanRoot]) {
        self.hasFullDiskAccess = hasFullDiskAccess
        self.availableRoots = availableRoots
    }

    // MARK: - Lifetimes

    public func windowDidOpen() async {
        let gen = generation
        let loaded = await actions.loadSummary()
        guard gen == generation, let loaded else { return }
        summary = loaded
    }

    public func pageDidAppear() async {
        let gen = generation
        let fda = await actions.hasFullDiskAccess()
        guard gen == generation else { return }
        hasFullDiskAccess = fda
        availableRoots = actions.availableRoots()
        guard spaceMap.tree == nil, scanTask == nil, phase == .idle else { return }
        phase = .loadingCache
        let epoch = cacheEpoch
        let cached = await actions.loadCached(root, classifyOptions)
        guard gen == generation, epoch == cacheEpoch else { return }
        if let (tree, overlay, set) = cached {
            adopt(tree: tree, overlay: overlay, cleanup: set)
        } else {
            phase = .idle
        }
    }

    /// Leaving the page cancels nothing: a scan keeps running and its results are there on return (spec §3.4).
    public func pageDidDisappear() {}

    public func windowDidClose() {
        generation += 1
        actions.cancelScan()
        if cleanTask != nil { actions.cancelClean() }
        // The engine keeps draining its own work; only the consumers stop.
        scanTask?.cancel()
        cleanTask?.cancel()
        flushTask?.cancel()
        scanTask = nil
        cleanTask = nil
        flushTask = nil
        run = nil
        actions.release()
        dropState()
        phase = .idle
    }

    private func dropState() {
        spaceMap.clear()
        cleanup.clear()
        progress.progress = nil
        hover.hoveredID = nil
        hasFinalTree = false
        setMeta = nil
        runItems = [:]
        lastCleaned = [:]
        listedAtStart = []
        forgetCleanHistory()
        policy = .none
    }

    /// A different tree: what was hidden, deferred or cleaned belonged to the old one.
    private func forgetCleanHistory() {
        pendingClassified = nil
        prunedItems = [:]
        cleanedNodeless = []
        pendingChanges = []
        pendingRemoved = []
        pendingUnchecked = []
        dirty = false
    }

    // MARK: - Scan

    public func selectRoot(_ newRoot: ScanRoot) async {
        guard newRoot != root, cleanTask == nil else { return }
        generation += 1
        let gen = generation
        if scanTask != nil { actions.cancelScan() }
        scanTask?.cancel()
        scanTask = nil
        dropState()
        root = newRoot
        phase = .loadingCache
        let epoch = cacheEpoch
        let cached = await actions.loadCached(newRoot, classifyOptions)
        guard gen == generation, epoch == cacheEpoch else { return }
        if let (tree, overlay, set) = cached {
            adopt(tree: tree, overlay: overlay, cleanup: set)
        } else {
            phase = .idle
            startScan()
        }
    }

    public func startScan() {
        guard scanTask == nil, canScan else { return }
        cacheEpoch += 1
        classifyOptions.now = now()
        phase = .scanning(hasPrevious: spaceMap.tree != nil)
        progress.progress = nil
        let stream = actions.scan(root, classifyOptions)
        let gen = generation
        scanTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == gen else { return }
                self.apply(event)
            }
            guard let self, self.generation == gen else { return }
            self.scanTask = nil
            // The stream ended without a terminal event (cancelled): don't stay in "scanning".
            if case .scanning = self.phase { self.phase = self.spaceMap.tree == nil ? .idle : .ready }
        }
    }

    public func cancelScan() {
        guard scanTask != nil else { return }
        actions.cancelScan()
    }

    public func apply(_ event: ScanEvent) {
        switch event {
        case let .progress(p):
            progress.progress = p
        case let .partial(tree):
            if !hasFinalTree { spaceMap.showPartial(tree) }
        case let .finished(tree):
            spaceMap.set(tree: tree, overlay: StorageTreeOverlay(tree: tree))
            cleanup.clear()
            forgetCleanHistory()
            setMeta = nil
            hasFinalTree = true
            progress.progress = nil
            policy = actions.policy()
            phase = .ready
        case let .classified(set):
            applyClassified(set)
        case let .failed(failure):
            progress.progress = nil
            phase = failure == .cancelled && hasFinalTree ? .ready : .failed(failure)
        }
    }

    /// Cache hit (page open) or a preview render: a finished tree with its classification.
    public func adopt(tree: StorageTree, overlay: StorageTreeOverlay, cleanup set: CleanupSet) {
        var overlay = overlay
        if overlay.treeVersion != tree.version {
            Self.log.fault("adopted overlay belongs to another tree, starting with an empty one")
            overlay = StorageTreeOverlay(tree: tree)
        }
        spaceMap.set(tree: tree, overlay: overlay)
        cleanup.clear()
        forgetCleanHistory()
        setMeta = nil
        hasFinalTree = true
        progress.progress = nil
        policy = actions.policy()
        phase = .ready
        applyClassified(set)
    }

    /// Settings changed (thresholds): classify the same tree again; the user's checks stay by path.
    public func applyClassifyOptions(_ options: ClassifyOptions) async {
        classifyOptions = options
        guard hasFinalTree else { return }
        let gen = generation
        let set = await actions.reclassify(options)
        guard gen == generation, let set else { return }
        applyClassified(set)
    }

    private func applyClassified(_ set: CleanupSet) {
        guard let tree = spaceMap.tree, let overlay = spaceMap.overlay, set.treeVersion == tree.version else { return }
        guard cleanTask == nil else {
            pendingClassified = set
            return
        }
        var meta = set
        meta.items = []
        // Trash bytes follow this session's trashing and emptying; a pass that predates them would undo that.
        if let known = setMeta?.trashBytes, set.treeVersion == setMeta?.treeVersion { meta.trashBytes = known }
        setMeta = meta
        var shown = set
        // A later pass classifies the immutable scan tree: the overlay stays the source of truth for what was
        // cleaned meanwhile.
        shown.items = set.items.compactMap { item in
            guard item.nodeID != nil else {
                return cleanedNodeless.contains(Self.nodelessKey(item)) ? nil : item
            }
            return presented(item, tree: tree, overlay: overlay)
        }
        cleanup.load(shown, tree: tree, overlay: overlay)
        refreshSummary()
    }

    private static func nodelessKey(_ item: CleanupItem) -> String { "\(item.mode.rawValue)|\(item.path)" }

    /// The item as the overlay shows it: nil when its node is gone, size and name/path as they are now (a shrunk
    /// folder, an undone trash that came back under another name).
    private func presented(_ item: CleanupItem, tree: StorageTree, overlay: StorageTreeOverlay) -> CleanupItem? {
        guard let node = item.nodeID else { return item }
        guard spaceMap.isVisible(node) else { return nil }
        var item = item
        do {
            if let size = try overlay.size(node, in: tree), size < item.allocBytes {
                let drop = item.allocBytes - size
                item.allocBytes = size
                item.privateBytesExcludingLinks = item.privateBytesExcludingLinks.map { $0 > drop ? $0 - drop : 0 }
            }
            let current = spaceMap.path(of: node)
            if current != tree.path(node) {
                item.path = current
                item.name = try overlay.name(node, in: tree)
            }
        } catch {
            overlayFailed(error)
        }
        return item
    }

    // MARK: - Clean

    /// Checked items that a process now holds open (spec §7.1 step 2): unchecked, marked in `cleanup.inUse`.
    public func recheckInUse() async -> [CleanupItem] {
        let gen = generation
        let checkedItems = cleanup.items.filter { cleanup.checked.contains($0.id) }
        guard !checkedItems.isEmpty else { return [] }
        let busy = await actions.checkInUse(checkedItems)
        guard gen == generation else { return [] }
        let found = checkedItems.filter { busy.contains($0.id) }
        cleanup.inUse.subtract(checkedItems.map(\.id))
        cleanup.inUse.formUnion(found.map(\.id))
        cleanup.uncheck(Set(found.map(\.id)))
        rebuildTotals()
        return found
    }

    /// false if a clean, undo or Empty Trash already runs, or the root does not allow cleaning these items.
    public func clean(_ items: [CleanupItem]) -> Bool {
        guard canStartRun, !items.isEmpty else { return false }
        guard root.allowsCleanup || items.allSatisfy({ $0.mode == .trash }) else { return false }
        listedAtStart = Set(items.map(\.id).filter { cleanup.item($0) != nil })
        runItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        lastCleaned = runItems
        begin(.clean, total: items.count, stream: actions.clean(items))
        return true
    }

    /// No other run, no scan or cache load in flight (the run is bound to the tree on screen).
    private var canStartRun: Bool { cleanTask == nil && busyReason == nil && phase != .loadingCache }

    /// "Move to Trash…" in the Space Map: a review-tier trash item for the node, with an id that cannot collide
    /// with the classifier's.
    public func trashItem(for node: StorageNodeID) -> CleanupItem? {
        guard let tree = spaceMap.tree, let overlay = spaceMap.overlay, node > 0, Int(node) < tree.nodeCount else {
            return nil
        }
        do {
            guard try !overlay.isRemoved(node, in: tree) else { return nil }
            let id = nextTrashItemID
            nextTrashItemID -= 1
            return CleanupItem(
                id: id, nodeID: node, path: spaceMap.path(of: node), name: try overlay.name(node, in: tree),
                category: .largeOld, tier: .review, mode: .trash, identity: tree.identity(node),
                allocBytes: try overlay.size(node, in: tree) ?? 0, sizeProvenance: .estimate)
        } catch {
            Self.log.fault("overlay does not match tree: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func cancelClean() {
        guard cleanTask != nil else { return }
        actions.cancelClean()
    }

    public func undoLast() -> Bool {
        guard canStartRun, let record = cleanup.lastUndo else { return false }
        runItems = lastCleaned
        begin(.undo, total: record.entries.count, stream: actions.undo(record))
        return true
    }

    public func emptyTrash() -> Bool {
        guard canStartRun, root.allowsCleanup else { return false }
        runItems = [:]
        begin(.emptyTrash, total: 0, stream: actions.emptyTrash())
        return true
    }

    private func begin(_ kind: Run, total: Int, stream: AsyncStream<CleanEvent>) {
        run = kind
        cleanup.skipped = []
        cleanup.lastReport = nil
        cleanup.cleanProgress = CleanProgress(total: total, processed: 0, phase: .detaching)
        let gen = generation
        let version = spaceMap.tree?.version
        cleanTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == gen else { return }
                // The run belongs to the tree it started on; its outcomes mean nothing for another one.
                guard self.spaceMap.tree?.version == version else { continue }
                self.applyDeferred(event)
            }
            guard let self, self.generation == gen else { return }
            self.cleanTask = nil
            self.run = nil
            // A stream that ends without `.finished` (engine gone) must not leave the footer on "Cleaning".
            self.cleanup.cleanProgress = nil
            self.flush()
            if let pending = self.pendingClassified {
                self.pendingClassified = nil
                self.applyClassified(pending)
            }
        }
    }

    public func apply(_ event: CleanEvent) {
        applyDeferred(event)
        flush()
    }

    private func markDirty() {
        dirty = true
        guard flushTask == nil else { return }
        // A stream hands events over one suspension each, so "next turn" would still flush once per event; a short
        // delay coalesces a burst. Run end and direct `apply` flush at once, so nothing waits on this.
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.flushDelay) } catch { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    /// Rebuilds what depends on the whole overlay: rows whose node is hidden (or back), item sizes, totals, summary.
    private func flush() {
        guard dirty else { return }
        dirty = false
        guard let tree = spaceMap.tree, let current = spaceMap.overlay else { return }
        // Removals first: an item cleaned and undone within one window must end up listed.
        cleanup.remove(ids: pendingRemoved)
        cleanup.update([], uncheck: pendingUnchecked)
        pendingRemoved = []
        pendingUnchecked = []
        applyPendingChanges(tree: tree, overlay: current)
        guard let overlay = spaceMap.overlay else { return }
        reconcileItems(tree: tree, overlay: overlay)
        rebuildTotals()
        refreshSummary()
    }

    private func reconcileItems(tree: StorageTree, overlay: StorageTreeOverlay) {
        var hidden = Set<Int32>()
        for item in cleanup.items {
            guard let node = item.nodeID, !spaceMap.isVisible(node) else { continue }
            prunedItems[item.id] = item
            hidden.insert(item.id)
        }
        cleanup.remove(ids: hidden)
        for (id, item) in prunedItems {
            guard let node = item.nodeID, spaceMap.isVisible(node) else { continue }
            prunedItems[id] = nil
            cleanup.append(item)
        }
        let changed = cleanup.items.compactMap { item -> CleanupItem? in
            guard let now = presented(item, tree: tree, overlay: overlay), now != item else { return nil }
            return now
        }
        cleanup.update(changed)
    }

    private func applyDeferred(_ event: CleanEvent) {
        switch event {
        case let .item(outcome):
            cleanup.cleanProgress?.processed += 1
            applyOutcome(outcome)
        case .freed:
            cleanup.cleanProgress?.phase = .freeing
        case let .restored(itemID, finalPath):
            applyRestored(itemID: itemID, finalPath: finalPath)
        case let .finished(report):
            finish(report)
        }
    }

    private func applyOutcome(_ outcome: CleanItemOutcome) {
        guard let tree = spaceMap.tree, spaceMap.overlay != nil else { return }
        if run == .emptyTrash {
            // Outcome ids are listing indices, not item ids: an entry is identified by its path. Only committed
            // entries change anything; failed and unprocessed ones stay.
            guard outcome.skip == nil else { return }
            pendingChanges.append(.removeNodes(outcome.removedNodes + trashEntryNode(outcome.path, in: tree)))
            removeTrashBytes(outcome.detachedBytes)
            markDirty()
            return
        }
        guard let item = runItems[outcome.itemID] ?? cleanup.item(outcome.itemID) else {
            Self.log.error("outcome for unknown item \(outcome.itemID, privacy: .public)")
            return
        }
        if let reason = outcome.skip {
            cleanup.skipped.removeAll { $0.item.id == item.id }
            cleanup.skipped.append((item, reason))
            return
        }
        pendingChanges.append(.outcome(outcome, item))
        if item.mode == .trash { addTrashBytes(outcome.detachedBytes > 0 ? outcome.detachedBytes : item.allocBytes) }
        if item.nodeID == nil { cleanedNodeless.insert(Self.nodelessKey(item)) }
        if item.keepParent, outcome.skippedChildren > 0 {
            // Part of the folder is still on disk: keep the row, smaller (sizes follow the overlay in `flush`),
            // no longer selected.
            pendingUnchecked.insert(item.id)
        } else {
            pendingRemoved.insert(item.id)
        }
        markDirty()
    }

    /// Node of a `~/.Trash` entry named by an outcome path; nothing for a path outside the Trash folder.
    private func trashEntryNode(_ path: String?, in tree: StorageTree) -> [StorageNodeID] {
        guard let path else { return [] }
        let trash = root.path + "/.Trash/"
        let full = path.hasPrefix("/") ? path : trash + path
        guard full.hasPrefix(trash), let node = tree.lookup(path: full), node != 0 else { return [] }
        return [node]
    }

    private func addTrashBytes(_ bytes: UInt64) {
        guard let known = setMeta?.trashBytes else { return }
        setMeta?.trashBytes = known + bytes
    }

    private func removeTrashBytes(_ bytes: UInt64) {
        guard let known = setMeta?.trashBytes else { return }
        setMeta?.trashBytes = known.subtractingSaturating(bytes)
    }

    private func applyRestored(itemID: Int32, finalPath: String) {
        guard spaceMap.tree != nil, spaceMap.overlay != nil,
              let item = runItems[itemID] ?? lastCleaned[itemID] else { return }
        pendingChanges.append(.restore(itemID: itemID, finalPath: finalPath, item: item,
                                       relist: listedAtStart.contains(itemID)))
        if item.mode == .trash { removeTrashBytes(item.allocBytes) }
        markDirty()
    }

    /// Overlay changes of the events since the last flush, applied together as one overlay batch.
    private enum PendingChange {
        case outcome(CleanItemOutcome, CleanupItem)
        case removeNodes([StorageNodeID])
        case restore(itemID: Int32, finalPath: String, item: CleanupItem, relist: Bool)
    }

    private func applyPendingChanges(tree: StorageTree, overlay: StorageTreeOverlay) {
        guard !pendingChanges.isEmpty else { return }
        let changes = pendingChanges
        pendingChanges = []
        var next = overlay
        do {
            try next.batch(in: tree) { (batch: inout StorageTreeOverlay) throws(StorageOverlayError) in
                for change in changes {
                    switch change {
                    case let .outcome(outcome, item):
                        try StorageCleanMath.apply(outcome, item: item, to: &batch, tree: tree)
                    case let .removeNodes(nodes):
                        for node in nodes { try batch.remove(node, kind: .deleted, in: tree) }
                    case let .restore(itemID, finalPath, item, _):
                        try StorageCleanMath.applyRestore(itemID: itemID, finalPath: finalPath, item: item,
                                                          to: &batch, tree: tree)
                    }
                }
            }
        } catch {
            overlayFailed(error)
        }
        spaceMap.setOverlay(next)
        for case let .restore(_, finalPath, item, relist) in changes where relist {
            var back = item
            back.path = finalPath
            back.name = (finalPath as NSString).lastPathComponent
            // Without a node to come back to the item is only a path; the Space Map shows it as a restored entry.
            if let node = item.nodeID, !spaceMap.isVisible(node) { back.nodeID = nil }
            cleanup.append(back)
        }
    }

    private func finish(_ report: CleanReport) {
        cleanup.cleanProgress = nil
        cleanup.lastReport = report
        switch run ?? .clean {
        case .clean:
            cleanup.lastUndo = report.undo
        case .undo:
            cleanup.lastUndo = nil
        case .emptyTrash:
            // Entries were applied one by one as they committed; the report adds nothing to infer from.
            break
        }
        policy = actions.policy()
        markDirty()
    }

    // MARK: - Misc actions

    public func ignore(path: String) {
        actions.ignore(path)
        classifyOptions.ignoredPaths.insert(path)
        cleanup.setIgnored(true, path: path)
        rebuildTotals()
        refreshSummary()
    }

    public func unignore(path: String) {
        actions.unignore(path)
        classifyOptions.ignoredPaths.remove(path)
        cleanup.setIgnored(false, path: path)
        rebuildTotals()
        refreshSummary()
    }

    public func reveal(path: String) {
        actions.revealInFinder(path)
    }

    // MARK: - Derived state

    private func rebuildTotals() {
        guard let tree = spaceMap.tree else { return }
        cleanup.rebuildTotals(tree: tree, overlay: spaceMap.overlay)
    }

    /// Home root only: the sidebar value and popover link describe the home scan.
    private func refreshSummary() {
        guard case .home = root, let tree = spaceMap.tree, let overlay = spaceMap.overlay, var set = setMeta else {
            return
        }
        set.items = cleanup.items
        let reclaimable: (bytes: UInt64, provenance: SizeProvenance)?
        do {
            reclaimable = try StorageCleanMath.reclaimable(set: set, tree: tree, overlay: overlay)
        } catch {
            overlayFailed(error)
            reclaimable = nil
        }
        summary = StorageSummary(root: root, scanDate: tree.scanDate, reclaimableBytes: reclaimable?.bytes,
                                 provenance: reclaimable?.provenance ?? .unavailable, trashBytes: set.trashBytes)
    }

    private func overlayFailed(_ error: StorageOverlayError) {
        Self.log.fault("overlay does not match tree: \(String(describing: error), privacy: .public)")
        cleanup.totalsUnavailable = true
    }
}

private extension UInt64 {
    func subtractingSaturating(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
