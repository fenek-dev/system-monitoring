import Foundation
import MonitorDiskTools
import MonitorLive
import MonitorModel
import os

/// Live storage backend (spec §3.1, §3.8): `StorageEngine` behind `StorageActions`. Besides passing events through
/// it keeps what outlives the window: the overlay sidecar (what cleaning changed since the cached scan) and the
/// summary file the sidebar reads without loading a tree.
///
/// Clean/undo/Empty Trash streams are teed. Each run captures the scan it was started against (tree, overlay,
/// classification, items); outcomes are collected and applied to that copy in one batch when the run finishes,
/// then the sidecar and summary are written for that scan before the consumer sees `.finished`. A run that
/// outlives the window therefore still persists its own scan, and never touches a tree opened later: the engine's
/// copies are replaced only while they still belong to the run's tree.
@MainActor final class StoragePipeline {
    nonisolated static let summaryFileName = "storage-summary.json"
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    private let engine: StorageEngine
    private let summaryURL: URL
    /// Latest classification of the open tree, minus items cleaned since.
    private var set: CleanupSet?
    /// Items handed to `clean` this session, by id: an undo refers to them.
    private var cleaned: [Int32: CleanupItem] = [:]

    init(engine: StorageEngine, dataDirectory: URL) {
        self.engine = engine
        summaryURL = dataDirectory.appendingPathComponent(Self.summaryFileName)
    }

    convenience init(dataDirectory: URL, home: String = NSHomeDirectory(), platform: StoragePlatform) {
        self.init(engine: StorageEngine(.live(home: home, dataDirectory: dataDirectory, platform: platform)),
                  dataDirectory: dataDirectory)
    }

    /// App quit: in-flight deletes stop; the next launch's sweep finishes their staging entries.
    func shutdown() {
        engine.abortDeletes()
    }

    var actions: StorageActions {
        StorageActions(
            scan: { [self] root, options in tee(engine.scan(root: root, options: options)) },
            cancelScan: { [engine] in engine.cancelScan() },
            loadCached: { [self] root, options in
                guard let loaded = await engine.loadCached(root: root, options: options) else { return nil }
                adopt(loaded.2)
                return loaded
            },
            loadSummary: { [self] in readSummary() },
            reclassify: { [self] options in
                guard let result = await engine.reclassify(options: options) else { return nil }
                adopt(result)
                return result
            },
            policy: { [engine] in engine.policy() },
            checkInUse: { [engine] items in await engine.checkInUse(items) },
            clean: { [self] items in
                let run = Run(engine: engine, set: set, items: Dictionary(items.map { ($0.id, $0) },
                                                                          uniquingKeysWith: { first, _ in first }))
                for item in items { cleaned[item.id] = item }
                return tee(engine.clean(items), kind: .clean, run: run)
            },
            cancelClean: { [engine] in engine.cancelClean() },
            undo: { [self] record in
                let run = Run(engine: engine, set: set, items: cleaned)
                return tee(engine.undo(record), kind: .undo, run: run)
            },
            emptyTrash: { [self] in
                tee(engine.emptyTrash(), kind: .emptyTrash, run: Run(engine: engine, set: set, items: [:]))
            },
            release: { [self] in
                engine.release()
                set = nil
                cleaned = [:]
            },
            availableRoots: { [engine] in engine.availableRoots() },
            hasFullDiskAccess: { [engine] in await engine.hasFullDiskAccess() })
    }

    // MARK: - Classification state

    /// A fresh classification predates this session's cleaning: what the overlay hides stays hidden and shrunk
    /// folders keep their new size. A set for a tree the engine no longer holds is dropped.
    private func adopt(_ fresh: CleanupSet) {
        guard let current = engine.current(), current.tree.version == fresh.treeVersion else { return }
        var next = fresh
        next.items = Self.projected(fresh.items, tree: current.tree, overlay: current.overlay)
        if let known = set?.trashBytes, set?.treeVersion == fresh.treeVersion { next.trashBytes = known }
        set = next
        if next.privateSizesFinal { writeSummary(current.root, tree: current.tree, overlay: current.overlay, set: next) }
    }

    /// The items as the model shows them after cleaning (`StorageModel.presented`): gone when their node is hidden
    /// (also through a trashed ancestor), smaller when part of the folder was cleaned.
    private static func projected(_ items: [CleanupItem], tree: StorageTree, overlay: StorageTreeOverlay)
        -> [CleanupItem] {
        items.compactMap { item in
            guard let node = item.nodeID else { return item }
            do {
                if try overlay.isRemoved(node, in: tree) { return nil }
                var shown = item
                if let size = try overlay.size(node, in: tree), size < item.allocBytes {
                    let drop = item.allocBytes - size
                    shown.allocBytes = size
                    shown.privateBytesExcludingLinks = item.privateBytesExcludingLinks.map { $0 > drop ? $0 - drop : 0 }
                }
                return shown
            } catch {
                log.error("overlay check failed for \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return item
            }
        }
    }

    private func tee(_ stream: AsyncStream<ScanEvent>) -> AsyncStream<ScanEvent> {
        let (out, continuation) = AsyncStream.makeStream(of: ScanEvent.self)
        Task { @MainActor [self] in
            for await event in stream {
                switch event {
                case .finished:
                    set = nil
                    cleaned = [:]
                case let .classified(classified):
                    adopt(classified)
                default:
                    break
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
        return out
    }

    // MARK: - Clean tee

    private enum RunKind { case clean, undo, emptyTrash }

    private enum Change {
        case outcome(CleanItemOutcome, CleanupItem)
        case removeNodes([StorageNodeID], bytes: UInt64)
        case restore(itemID: Int32, finalPath: String, item: CleanupItem)
    }

    /// The scan a run works on, captured when the run is requested (nil: no scan was loaded).
    private struct Run {
        var root: ScanRoot
        var tree: StorageTree
        var overlay: StorageTreeOverlay
        var set: CleanupSet?
        var items: [Int32: CleanupItem]

        @MainActor init?(engine: StorageEngine, set: CleanupSet?, items: [Int32: CleanupItem]) {
            guard let current = engine.current() else { return nil }
            root = current.root
            tree = current.tree
            overlay = current.overlay
            self.set = set?.treeVersion == current.tree.version ? set : nil
            self.items = items
        }
    }

    private func tee(_ stream: AsyncStream<CleanEvent>, kind: RunKind, run: Run?) -> AsyncStream<CleanEvent> {
        let (out, continuation) = AsyncStream.makeStream(of: CleanEvent.self)
        Task { @MainActor [self] in
            var changes: [Change] = []
            for await event in stream {
                switch event {
                case let .item(outcome):
                    if let run, let change = change(for: outcome, kind: kind, run: run) { changes.append(change) }
                case let .restored(itemID, finalPath):
                    if let item = run?.items[itemID] {
                        changes.append(.restore(itemID: itemID, finalPath: finalPath, item: item))
                    }
                case .finished:
                    if let run { await persist(changes, run: run) }
                    changes = []
                case .freed:
                    break
                }
                continuation.yield(event)
            }
            // A stream that ends without `.finished` still persists what it did.
            if let run, !changes.isEmpty { await persist(changes, run: run) }
            continuation.finish()
        }
        return out
    }

    private func change(for outcome: CleanItemOutcome, kind: RunKind, run: Run) -> Change? {
        guard outcome.skip == nil else { return nil }
        if kind == .emptyTrash {
            // Outcome ids are listing indices: an entry is identified by its path.
            let node = outcome.path.flatMap { trashEntryNode($0, tree: run.tree) }
            return .removeNodes(outcome.removedNodes + (node.map { [$0] } ?? []), bytes: outcome.detachedBytes)
        }
        guard let item = run.items[outcome.itemID] else {
            Self.log.error("outcome for unknown item \(outcome.itemID, privacy: .public)")
            return nil
        }
        return .outcome(outcome, item)
    }

    private func trashEntryNode(_ path: String, tree: StorageTree) -> StorageNodeID? {
        let trash = tree.root.path + "/.Trash/"
        let full = path.hasPrefix("/") ? path : trash + path
        guard full.hasPrefix(trash), let node = tree.lookup(path: full), node != 0 else { return nil }
        return node
    }

    /// Applies a run's changes to its own copy of the scan, writes that scan's sidecar and summary, and hands the
    /// result to the engine only while the engine still holds the same tree.
    private func persist(_ changes: [Change], run: Run) async {
        guard !changes.isEmpty else { return }
        var overlay = run.overlay
        do {
            try overlay.batch(in: run.tree) { (batch: inout StorageTreeOverlay) throws(StorageOverlayError) in
                for change in changes {
                    switch change {
                    case let .outcome(outcome, item):
                        try StorageCleanMath.apply(outcome, item: item, to: &batch, tree: run.tree)
                    case let .removeNodes(nodes, _):
                        for node in nodes { try batch.remove(node, kind: .deleted, in: run.tree) }
                    case let .restore(itemID, finalPath, item):
                        try StorageCleanMath.applyRestore(itemID: itemID, finalPath: finalPath, item: item,
                                                          to: &batch, tree: run.tree)
                    }
                }
            }
        } catch {
            Self.log.error("overlay update failed after clean: \(String(describing: error), privacy: .public)")
        }
        let next = Self.updated(run.set, for: changes)
        await engine.saveOverlay(overlay)
        let held = engine.current()?.tree.version == run.tree.version
        if held {
            engine.replaceOverlay(overlay)
            if set?.treeVersion == run.tree.version { set = next }
        }
        // Another tree is open: its summary is not this run's to overwrite. No tree open: this scan is the latest.
        if held || engine.current() == nil, let next {
            writeSummary(run.root, tree: run.tree, overlay: overlay, set: next)
        }
    }

    private static func updated(_ set: CleanupSet?, for changes: [Change]) -> CleanupSet? {
        guard var next = set else { return nil }
        for change in changes {
            switch change {
            case let .outcome(outcome, item):
                let partial = item.keepParent && outcome.skippedChildren > 0
                if !partial { next.items.removeAll { $0.id == item.id } }
                if item.mode == .trash {
                    next.trashBytes = next.trashBytes.map { $0 + (outcome.detachedBytes > 0 ? outcome.detachedBytes : item.allocBytes) }
                }
            case let .removeNodes(_, bytes):
                next.trashBytes = next.trashBytes.map { $0 > bytes ? $0 - bytes : 0 }
            case let .restore(_, finalPath, item):
                if item.mode == .trash { next.trashBytes = next.trashBytes.map { $0 > item.allocBytes ? $0 - item.allocBytes : 0 } }
                if item.nodeID != nil, !next.items.contains(where: { $0.id == item.id }) {
                    var back = item
                    back.path = finalPath
                    back.name = (finalPath as NSString).lastPathComponent
                    next.items.append(back)
                }
            }
        }
        return next
    }

    // MARK: - Summary file

    /// Home root only (the sidebar and popover describe the home scan). Counts what the overlay leaves: the same
    /// projection as the page, so the sidebar never shows data that was cleaned (or sits in a trashed parent).
    private func writeSummary(_ root: ScanRoot, tree: StorageTree, overlay: StorageTreeOverlay, set: CleanupSet) {
        guard case .home = root else { return }
        var shown = set
        shown.items = Self.projected(set.items, tree: tree, overlay: overlay)
        let reclaimable: (bytes: UInt64, provenance: SizeProvenance)
        do {
            reclaimable = try StorageCleanMath.reclaimable(set: shown, tree: tree, overlay: overlay)
        } catch {
            Self.log.error("summary not written, reclaimable failed: \(String(describing: error), privacy: .public)")
            return
        }
        // A newer scan's summary stays: a late write from an older scan (a run that outlived its window) loses.
        if let existing = readSummary(), existing.scanDate > tree.scanDate { return }
        let summary = StorageSummary(root: root, scanDate: tree.scanDate, reclaimableBytes: reclaimable.bytes,
                                     provenance: reclaimable.provenance, trashBytes: set.trashBytes)
        do {
            try FileManager.default.createDirectory(at: summaryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(summary).write(to: summaryURL, options: .atomic)
        } catch {
            Self.log.error("summary \(self.summaryURL.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readSummary() -> StorageSummary? {
        let data: Data
        do { data = try Data(contentsOf: summaryURL) } catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
            if !missing { Self.log.error("summary \(self.summaryURL.path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)") }
            return nil
        }
        do { return try JSONDecoder().decode(StorageSummary.self, from: data) } catch {
            Self.log.error("summary \(self.summaryURL.path, privacy: .public) corrupt: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
