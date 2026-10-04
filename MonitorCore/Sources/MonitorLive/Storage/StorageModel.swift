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

    public init(actions: StorageActions, home: String = NSHomeDirectory(),
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.actions = actions
        self.now = now
        root = .home(home)
        classifyOptions = ClassifyOptions(now: now())
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
        let cached = await actions.loadCached(root, classifyOptions)
        guard gen == generation else { return }
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
        scanTask = nil
        cleanTask = nil
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
        policy = .none
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
        let cached = await actions.loadCached(newRoot, classifyOptions)
        guard gen == generation else { return }
        if let (tree, overlay, set) = cached {
            adopt(tree: tree, overlay: overlay, cleanup: set)
        } else {
            phase = .idle
            startScan()
        }
    }

    public func startScan() {
        guard scanTask == nil else { return }
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
        var meta = set
        meta.items = []
        setMeta = meta
        var shown = set
        // A later pass classifies the immutable scan tree: what was cleaned meanwhile must stay gone.
        shown.items = set.items.filter { item in
            guard let node = item.nodeID else { return true }
            return spaceMap.isVisible(node)
        }
        cleanup.load(shown, tree: tree, overlay: overlay)
        refreshSummary()
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
        guard cleanTask == nil, !items.isEmpty else { return false }
        guard root.allowsCleanup || items.allSatisfy({ $0.mode == .trash }) else { return false }
        listedAtStart = Set(items.map(\.id).filter { cleanup.item($0) != nil })
        runItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        lastCleaned = runItems
        begin(.clean, total: items.count, stream: actions.clean(items))
        return true
    }

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
                id: id, nodeID: node, path: tree.path(node), name: try overlay.name(node, in: tree),
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
        guard cleanTask == nil, let record = cleanup.lastUndo else { return false }
        runItems = lastCleaned
        begin(.undo, total: record.entries.count, stream: actions.undo(record))
        return true
    }

    public func emptyTrash() -> Bool {
        guard cleanTask == nil, root.allowsCleanup else { return false }
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
        cleanTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == gen else { return }
                self.apply(event)
            }
            guard let self, self.generation == gen else { return }
            self.cleanTask = nil
            self.run = nil
            // A stream that ends without `.finished` (engine gone) must not leave the footer on "Cleaning".
            self.cleanup.cleanProgress = nil
        }
    }

    public func apply(_ event: CleanEvent) {
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
        guard let tree = spaceMap.tree, var overlay = spaceMap.overlay else { return }
        if run == .emptyTrash {
            // Outcome ids are listing indices, not item ids: only reported nodes can be applied.
            guard outcome.skip == nil, !outcome.removedNodes.isEmpty else { return }
            do {
                for node in outcome.removedNodes { try overlay.remove(node, kind: .deleted, in: tree) }
            } catch {
                overlayFailed(error)
                return
            }
            spaceMap.setOverlay(overlay)
            rebuildTotals()
            refreshSummary()
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
        do {
            try StorageCleanMath.apply(outcome, item: item, to: &overlay, tree: tree)
        } catch {
            overlayFailed(error)
            return
        }
        spaceMap.setOverlay(overlay)
        if item.keepParent, outcome.skippedChildren > 0 {
            // Part of the folder is still on disk: keep the row, smaller, no longer selected.
            var rest = cleanup.item(item.id) ?? item
            rest.allocBytes = rest.allocBytes.subtractingSaturating(outcome.detachedBytes)
            rest.privateBytesExcludingLinks = rest.privateBytesExcludingLinks?
                .subtractingSaturating(outcome.detachedBytes)
            cleanup.replace(rest, checked: false)
        } else {
            cleanup.remove(ids: [item.id])
        }
        rebuildTotals()
        refreshSummary()
    }

    private func applyRestored(itemID: Int32, finalPath: String) {
        guard let tree = spaceMap.tree, var overlay = spaceMap.overlay,
              let item = runItems[itemID] ?? lastCleaned[itemID] else { return }
        do {
            try StorageCleanMath.applyRestore(itemID: itemID, finalPath: finalPath, item: item, to: &overlay,
                                              tree: tree)
        } catch {
            overlayFailed(error)
            return
        }
        spaceMap.setOverlay(overlay)
        if listedAtStart.contains(itemID) {
            var back = item
            back.path = finalPath
            // Without a node to come back to the item is only a path; the Space Map shows it as a restored entry.
            if let node = item.nodeID, !spaceMap.isVisible(node) { back.nodeID = nil }
            cleanup.append(back)
        }
        rebuildTotals()
        refreshSummary()
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
            finishEmptyTrash(report)
        }
        policy = actions.policy()
        refreshSummary()
    }

    private func finishEmptyTrash(_ report: CleanReport) {
        if let tree = spaceMap.tree, var overlay = spaceMap.overlay,
           let trash = tree.lookup(path: root.path + "/.Trash") {
            do {
                try overlay.shrink(trash, by: report.freedBytes, in: tree)
                spaceMap.setOverlay(overlay)
            } catch {
                overlayFailed(error)
            }
        }
        if !report.cancelled {
            cleanup.remove(ids: Set(cleanup.items.filter { $0.category == .trash }.map(\.id)))
        }
        if let trashBytes = setMeta?.trashBytes {
            setMeta?.trashBytes = trashBytes.subtractingSaturating(report.freedBytes)
        }
        rebuildTotals()
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
