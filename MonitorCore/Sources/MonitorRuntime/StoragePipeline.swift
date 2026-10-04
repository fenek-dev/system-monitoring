import Foundation
import MonitorDiskTools
import MonitorLive
import MonitorModel
import os

/// Live storage backend (spec §3.1, §3.8): `StorageEngine` behind `StorageActions`. Besides passing events through
/// it keeps what outlives the window: the overlay sidecar (what cleaning changed since the cached scan) and the
/// summary file the sidebar reads without loading a tree.
///
/// Clean/undo/Empty Trash streams are teed: outcomes are collected as they arrive and applied to the engine's
/// overlay in one batch when the run finishes (one overlay recompute instead of one per item), then the sidecar and
/// summary are written before the consumer sees `.finished`. The tee task keeps running if the consumer goes away,
/// so a run that outlives the window still ends with persisted state.
@MainActor final class StoragePipeline {
    nonisolated static let summaryFileName = "storage-summary.json"
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    private let engine: StorageEngine
    private let summaryURL: URL
    /// Latest classification of the open tree, minus items cleaned since.
    private var set: CleanupSet?
    /// Items handed to `clean`, by id: outcomes and undo events refer to them.
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
                for item in items { cleaned[item.id] = item }
                return tee(engine.clean(items), kind: .clean)
            },
            cancelClean: { [engine] in engine.cancelClean() },
            undo: { [self] record in tee(engine.undo(record), kind: .undo) },
            emptyTrash: { [self] in tee(engine.emptyTrash(), kind: .emptyTrash) },
            release: { [self] in
                engine.release()
                set = nil
                cleaned = [:]
            },
            availableRoots: { [engine] in engine.availableRoots() },
            hasFullDiskAccess: { [engine] in await engine.hasFullDiskAccess() })
    }

    // MARK: - Classification state

    /// A fresh classification predates this session's cleaning: items already gone stay gone.
    private func adopt(_ fresh: CleanupSet) {
        var next = fresh
        if let current = engine.current() {
            next.items = fresh.items.filter { item in
                guard let node = item.nodeID else { return true }
                do { return try !current.overlay.isRemoved(node, in: current.tree) } catch {
                    Self.log.error("overlay check failed for \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    return true
                }
            }
            if let known = set?.trashBytes, set?.treeVersion == fresh.treeVersion { next.trashBytes = known }
        }
        set = next
        if next.privateSizesFinal { writeSummary() }
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

    private func tee(_ stream: AsyncStream<CleanEvent>, kind: RunKind) -> AsyncStream<CleanEvent> {
        let (out, continuation) = AsyncStream.makeStream(of: CleanEvent.self)
        Task { @MainActor [self] in
            var changes: [Change] = []
            for await event in stream {
                switch event {
                case let .item(outcome):
                    if let change = change(for: outcome, kind: kind) { changes.append(change) }
                case let .restored(itemID, finalPath):
                    if let item = cleaned[itemID] { changes.append(.restore(itemID: itemID, finalPath: finalPath, item: item)) }
                case .finished:
                    await persist(changes)
                    changes = []
                case .freed:
                    break
                }
                continuation.yield(event)
            }
            // A stream that ends without `.finished` (engine bug, cancelled consumer upstream) still persists.
            if !changes.isEmpty { await persist(changes) }
            continuation.finish()
        }
        return out
    }

    private func change(for outcome: CleanItemOutcome, kind: RunKind) -> Change? {
        guard outcome.skip == nil else { return nil }
        if kind == .emptyTrash {
            // Outcome ids are listing indices: an entry is identified by its path.
            let tree = engine.current()?.tree
            let node = outcome.path.flatMap { path in trashEntryNode(path, tree: tree) }
            return .removeNodes(outcome.removedNodes + (node.map { [$0] } ?? []), bytes: outcome.detachedBytes)
        }
        guard let item = cleaned[outcome.itemID] else {
            Self.log.error("outcome for unknown item \(outcome.itemID, privacy: .public)")
            return nil
        }
        return .outcome(outcome, item)
    }

    private func trashEntryNode(_ path: String, tree: StorageTree?) -> StorageNodeID? {
        guard let tree else { return nil }
        let trash = tree.root.path + "/.Trash/"
        let full = path.hasPrefix("/") ? path : trash + path
        guard full.hasPrefix(trash), let node = tree.lookup(path: full), node != 0 else { return nil }
        return node
    }

    /// Applies a run's changes to the engine's overlay and the held set, then writes sidecar and summary.
    private func persist(_ changes: [Change]) async {
        guard !changes.isEmpty, let current = engine.current() else { return }
        var overlay = current.overlay
        do {
            try overlay.batch(in: current.tree) { (batch: inout StorageTreeOverlay) throws(StorageOverlayError) in
                for change in changes {
                    switch change {
                    case let .outcome(outcome, item):
                        try StorageCleanMath.apply(outcome, item: item, to: &batch, tree: current.tree)
                    case let .removeNodes(nodes, _):
                        for node in nodes { try batch.remove(node, kind: .deleted, in: current.tree) }
                    case let .restore(itemID, finalPath, item):
                        try StorageCleanMath.applyRestore(itemID: itemID, finalPath: finalPath, item: item,
                                                          to: &batch, tree: current.tree)
                    }
                }
            }
        } catch {
            Self.log.error("overlay update failed after clean: \(String(describing: error), privacy: .public)")
        }
        guard engine.replaceOverlay(overlay) else { return }
        updateSet(for: changes)
        await engine.saveOverlay()
        writeSummary()
    }

    private func updateSet(for changes: [Change]) {
        guard var next = set else { return }
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
        set = next
    }

    // MARK: - Summary file

    /// Home root only: the sidebar and popover describe the home scan.
    private func writeSummary() {
        guard let current = engine.current(), case .home = current.root, let set else { return }
        let reclaimable: (bytes: UInt64, provenance: SizeProvenance)
        do {
            reclaimable = try StorageCleanMath.reclaimable(set: set, tree: current.tree, overlay: current.overlay)
        } catch {
            Self.log.error("summary not written, reclaimable failed: \(String(describing: error), privacy: .public)")
            return
        }
        let summary = StorageSummary(root: current.root, scanDate: current.tree.scanDate,
                                     reclaimableBytes: reclaimable.bytes, provenance: reclaimable.provenance,
                                     trashBytes: set.trashBytes)
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
