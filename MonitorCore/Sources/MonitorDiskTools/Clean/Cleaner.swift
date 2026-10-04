import Darwin
import Foundation
import MonitorModel
import os
import Synchronization

public struct CleanContext: Sendable {
    public var home: String
    /// Everything the cleaner touches must be below this root (the scan root for Trash / evict / remove).
    public var permittedRoot: String
    public var stagingDir: String
    /// Our own data directories; never cleaned, nor anything containing or inside them.
    public var dataDirectories: [String]
    public var trash: any TrashMover
    public var deleter: any Deleter
    public var evictor: any Evictor
    public var simctl: any SimctlRunner
    /// Items held open by a process are skipped (`.inUse`) when set.
    public var inUse: InUseChecker?
    public var log: Logger

    public init(home: String, permittedRoot: String, stagingDir: String, dataDirectories: [String],
                trash: any TrashMover, deleter: any Deleter, evictor: any Evictor, simctl: any SimctlRunner,
                inUse: InUseChecker? = nil, log: Logger = DiskTools.log) {
        self.home = home
        self.permittedRoot = permittedRoot
        self.stagingDir = stagingDir
        self.dataDirectories = dataDirectories
        self.trash = trash
        self.deleter = deleter
        self.evictor = evictor
        self.simctl = simctl
        self.inUse = inUse
        self.log = log
    }
}

/// The only code that deletes or moves user files. One clean at a time per `Cleaner`.
///
/// Detaching is serial (journal rename, Trash, evict) and deleting is a pool of at most `maxInFlight` workers. The
/// detach loop waits for a free worker slot before taking the next item, so after `cancel()` at most that many
/// committed entries are left to drain, and a crash leaves few entries for the launch sweep.
public final class Cleaner: Sendable {
    static let maxInFlight = 4

    private let context: CleanContext
    private let hooks: CleanTestHooks
    private let staging: Staging
    private let cancelled = Mutex(false)
    private let detachQueue = DispatchQueue(label: "dev.telltale.cleaner.detach")
    private let deletePool = DispatchQueue(label: "dev.telltale.cleaner.delete", attributes: .concurrent)

    public convenience init(context: CleanContext) {
        self.init(context: context, hooks: CleanTestHooks())
    }

    init(context: CleanContext, hooks: CleanTestHooks) {
        self.context = context
        self.hooks = hooks
        self.staging = Staging(dir: context.stagingDir, deleter: context.deleter)
    }

    /// Stops detaching further items. Entries already committed keep deleting; the stream still ends with exactly
    /// one `.finished`.
    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// App quit: aborts deletions in flight. Their entries stay in `commit/` for the next launch sweep.
    public func abortDeletes() {
        context.deleter.cancelInFlight()
    }

    public func clean(_ items: [CleanupItem], tree: StorageTree,
                      overlay: StorageTreeOverlay) -> AsyncStream<CleanEvent> {
        // Reset here, not on the queue: a `cancel()` right after this call returns must not be lost.
        cancelled.withLock { $0 = false }
        return AsyncStream { continuation in
            detachQueue.async { [self] in
                let run = Run(continuation: continuation)
                runClean(items, tree: tree, overlay: overlay, run: run)
                run.finish()
            }
        }
    }

    /// Journal-removes every child of `~/.Trash`. Entries owned by the user with `uchg` are unlocked first.
    public func emptyTrash() -> AsyncStream<CleanEvent> {
        cancelled.withLock { $0 = false }
        return AsyncStream { continuation in
            detachQueue.async { [self] in
                let run = Run(continuation: continuation)
                runEmptyTrash(run: run)
                run.finish()
            }
        }
    }

    // MARK: - Run state

    private struct Accumulator: Sendable {
        var outcomes: [Int: CleanItemOutcome] = [:]
        var partial: Set<Int> = []
        var freed: UInt64 = 0
        var trashed: UInt64 = 0
        var evicted: UInt64 = 0
        var leftovers = 0
        var undo: [UndoEntry] = []
        var sawCancel = false
    }

    private final class Run: Sendable {
        let continuation: AsyncStream<CleanEvent>.Continuation
        let slots = DispatchSemaphore(value: Cleaner.maxInFlight)
        let group = DispatchGroup()
        let acc = Mutex(Accumulator())

        init(continuation: AsyncStream<CleanEvent>.Continuation) {
            self.continuation = continuation
        }

        func record(_ outcome: CleanItemOutcome, at index: Int) {
            acc.withLock { $0.outcomes[index] = outcome }
            continuation.yield(.item(outcome))
        }

        func finish() {
            // Detaching stopped; wait for every committed entry to be deleted before the single `.finished`.
            group.wait()
            let report = acc.withLock { acc -> CleanReport in
                var outcomes = acc.outcomes.sorted { $0.key < $1.key }.map(\.value)
                for i in outcomes.indices where acc.partial.contains(i) { outcomes[i].partial = true }
                return CleanReport(freedBytes: acc.freed, trashedBytes: acc.trashed, evictedBytes: acc.evicted,
                                   outcomes: outcomes, cancelled: acc.sawCancel, stagingLeftovers: acc.leftovers,
                                   undo: acc.undo.isEmpty ? nil : UndoRecord(date: Date(), entries: acc.undo))
            }
            continuation.yield(.finished(report))
            continuation.finish()
        }
    }

    /// Everything a file-touching item needs, opened once per run. A failure is an item-level skip, never a throw.
    private struct Setup {
        var root: Result<TrustedRoot, SafePathError>
        var journal: Result<StagingJournal, SafePathError>
        var denylist: Denylist
    }

    // MARK: - Clean

    private func runClean(_ items: [CleanupItem], tree: StorageTree, overlay: StorageTreeOverlay, run: Run) {
        let needsFiles = items.contains { [.remove, .trash, .evict].contains($0.mode) }
        let setup = needsFiles ? makeSetup(scanRoot: tree.root.path, needsJournal: items.contains { $0.mode == .remove }) : nil
        let held = context.inUse?.inUse(items.filter { [.remove, .trash, .evict].contains($0.mode) }) ?? []

        for (index, item) in items.enumerated() {
            hooks.beforeItem?(index)
            if isCancelled() {
                run.acc.withLock { $0.sawCancel = true }
                run.record(CleanItemOutcome(itemID: item.id, skip: .cancelled), at: index)
                continue
            }
            let outcome = process(item, index: index, tree: tree, overlay: overlay, setup: setup,
                                  inUse: held.contains(item.id), run: run)
            run.record(outcome, at: index)
        }
    }

    private func makeSetup(scanRoot: String, needsJournal: Bool) -> Setup {
        let root: Result<TrustedRoot, SafePathError>
        do { root = .success(try TrustedRoot(path: context.permittedRoot)) } catch { root = .failure(error) }
        let journal: Result<StagingJournal, SafePathError>
        if needsJournal {
            do { journal = .success(try staging.openJournal(hooks: hooks)) } catch { journal = .failure(error) }
        } else {
            journal = .failure(.invalidPath("journal not needed"))
        }
        let denylist = Denylist.build(home: context.home, scanRoot: scanRoot, dataDirectories: context.dataDirectories)
        return Setup(root: root, journal: journal, denylist: denylist)
    }

    private func isCancelled() -> Bool {
        cancelled.withLock { $0 }
    }

    private func process(_ item: CleanupItem, index: Int, tree: StorageTree, overlay: StorageTreeOverlay,
                         setup: Setup?, inUse: Bool, run: Run) -> CleanItemOutcome {
        var outcome = CleanItemOutcome(itemID: item.id)
        let bytes = item.privateBytesExcludingLinks ?? item.allocBytes

        switch item.mode {
        case .none:
            outcome.skip = .notPermitted
            return outcome
        case .simctl:
            // Never touches the simulators' directory itself; only the injected runner runs.
            switch context.simctl.deleteUnavailable() {
            case .success:
                outcome.detachedBytes = bytes
                context.log.notice("simctl: deleted unavailable simulators, \(bytes) bytes")
                run.acc.withLock { $0.freed += bytes }
                run.continuation.yield(.freed(bytes))
            case let .failed(message):
                outcome.skip = .failed(message)
            }
            return outcome
        case .remove, .trash, .evict:
            break
        }

        guard let setup else {
            outcome.skip = .failed("not set up")
            return outcome
        }
        if inUse {
            outcome.skip = .inUse
            return outcome
        }
        if item.mode == .remove, !isBelow(item.path, root: context.home) {
            outcome.skip = .denied(.removeOutsideHome)
            return outcome
        }
        if let node = item.nodeID {
            do {
                if try overlay.isRemoved(node, in: tree) { return vanished(item, outcome) }
            } catch {
                // Overlay of another tree: nothing about this item can be verified.
                outcome.skip = .denied(.unverifiable)
                return outcome
            }
        }
        guard let expected = item.identity ?? item.nodeID.map(tree.identity) else {
            outcome.skip = .failed("no scan identity")
            return outcome
        }
        let root: TrustedRoot
        switch setup.root {
        case let .success(r): root = r
        case let .failure(error):
            outcome.skip = CleanFS.skipReason(for: error)
            return outcome
        }

        let live: LiveTarget
        do {
            live = try LiveTarget.open(root: root, absolutePath: item.path)
        } catch {
            let reason = CleanFS.skipReason(for: error)
            return reason == .vanished ? vanished(item, outcome) : skipped(outcome, reason)
        }
        if let reason = setup.denylist.check(chain: live.chain) {
            outcome.skip = .denied(reason)
            return outcome
        }

        switch item.mode {
        case .trash:
            return trash(item, live: live, expected: expected, bytes: bytes, outcome: outcome, run: run)
        case .evict:
            return evict(item, live: live, expected: expected, bytes: bytes, outcome: outcome, run: run)
        default:
            break
        }

        guard case let .success(journal) = setup.journal else {
            outcome.skip = .failed("staging unavailable")
            return outcome
        }
        if item.keepParent {
            return removeChildren(item, live: live, expected: expected, tree: tree, journal: journal,
                                  outcome: outcome, index: index, run: run)
        }
        return removeWhole(item, live: live, expected: expected, bytes: bytes, journal: journal,
                           outcome: outcome, index: index, run: run)
    }

    private func skipped(_ outcome: CleanItemOutcome, _ reason: SkipReason) -> CleanItemOutcome {
        var outcome = outcome
        outcome.skip = reason
        return outcome
    }

    /// Gone before we got to it. A permanent delete's goal is met (success, 0 B); a Trash / evict request is
    /// reported so the UI doesn't claim it moved something.
    private func vanished(_ item: CleanupItem, _ outcome: CleanItemOutcome) -> CleanItemOutcome {
        var outcome = outcome
        if item.mode == .remove {
            outcome.removedNodes = item.nodeID.map { [$0] } ?? []
        } else {
            outcome.skip = .vanished
        }
        return outcome
    }

    /// `path` equal to or below `root`, by whole components (also against the canonical spelling of `root`).
    private func isBelow(_ path: String, root: String) -> Bool {
        if (try? RelativePath.confined(path, under: root)) != nil { return true }
        guard let resolved = Darwin.realpath(root, nil) else { return false }
        defer { free(resolved) }
        return (try? RelativePath.confined(path, under: String(cString: resolved))) != nil
    }

    // MARK: - Trash / evict

    private func trash(_ item: CleanupItem, live: borrowing LiveTarget, expected: FileIdentity, bytes: UInt64,
                       outcome: CleanItemOutcome, run: Run) -> CleanItemOutcome {
        var outcome = outcome
        guard live.identity == expected else {
            outcome.skip = .changedSinceScan
            return outcome
        }
        let resulting: String
        do {
            // Accepted window: `trashItem` takes a URL, so the path is resolved again after the identity check above.
            // The system writes the Put Back metadata, which is why we don't rename into `.Trash` ourselves.
            resulting = try context.trash.trash(path: item.path)
        } catch {
            switch error {
            case .noTrash: outcome.skip = .noTrash
            case .vanished: outcome.skip = .vanished
            case let .failed(message): outcome.skip = .failed(message)
            }
            return outcome
        }
        outcome.detachedBytes = bytes
        outcome.removedNodes = item.nodeID.map { [$0] } ?? []
        outcome.trashedTo = resulting
        context.log.notice("trashed \(item.path, privacy: .public) -> \(resulting, privacy: .public), \(bytes) bytes, mode trash")
        let entry = undoEntry(item, expected: expected, resulting: resulting)
        run.acc.withLock {
            $0.trashed += bytes
            if let entry { $0.undo.append(entry) }
        }
        return outcome
    }

    /// Where the item landed and which inode it is there, for a safe undo later. Without it the item is still in the
    /// Trash (the user can Put Back), just not undoable from the app.
    private func undoEntry(_ item: CleanupItem, expected: FileIdentity, resulting: String) -> UndoEntry? {
        let parentPath = (resulting as NSString).deletingLastPathComponent
        do {
            let trashRoot = try TrustedRoot(path: parentPath)
            let rel = try trashRoot.relativePath(of: resulting)
            guard rel.components.count == 1 else { throw SafePathError.outsideRoot }
            let landed = trashRoot.withDescriptor { CleanFS.identity(of: rel.leaf, in: $0) }
            if landed != expected {
                context.log.error("trash: \(resulting, privacy: .public) is not the inode that was trashed")
            }
            return UndoEntry(itemID: item.id, nodeID: item.nodeID, originalPath: item.path, trashPath: resulting,
                             identity: landed ?? expected, trashParentPath: parentPath,
                             trashParentIdentity: trashRoot.identity)
        } catch {
            context.log.error("trash: no undo record for \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func evict(_ item: CleanupItem, live: borrowing LiveTarget, expected: FileIdentity, bytes: UInt64,
                       outcome: CleanItemOutcome, run: Run) -> CleanItemOutcome {
        var outcome = outcome
        guard live.identity == expected else {
            outcome.skip = .changedSinceScan
            return outcome
        }
        do {
            // Accepted window: `evictUbiquitousItem` takes a URL, resolved again after the identity check.
            try context.evictor.evict(path: item.path)
        } catch {
            outcome.skip = .failed("evict: \(error)")
            return outcome
        }
        outcome.detachedBytes = bytes
        context.log.notice("evicted \(item.path, privacy: .public), \(bytes) bytes, mode evict")
        run.acc.withLock { $0.evicted += bytes }
        return outcome
    }

    // MARK: - Remove

    private func removeWhole(_ item: CleanupItem, live: borrowing LiveTarget, expected: FileIdentity,
                             bytes: UInt64, journal: StagingJournal, outcome: CleanItemOutcome, index: Int,
                             run: Run) -> CleanItemOutcome {
        var outcome = outcome
        switch detach(parent: live.parent.rawValue, parentPath: (item.path as NSString).deletingLastPathComponent,
                      parentIdentity: live.parentIdentity, leaf: live.leaf, expected: expected, bytes: bytes,
                      journal: journal, index: index, run: run, clearImmutable: false) {
        case .committed:
            outcome.detachedBytes = bytes
            outcome.removedNodes = item.nodeID.map { [$0] } ?? []
            context.log.notice("detached \(item.path, privacy: .public), \(bytes) bytes, mode remove")
        case .cancelled:
            outcome.skip = .cancelled
        case let .skipped(reason):
            outcome.skip = reason
            if reason == .vanished { return vanished(item, outcome) }
        }
        return outcome
    }

    /// Keep-parent: the directory stays; each child is read from the live listing and detached on its own, so a
    /// child created after the scan is handled and one replaced after the listing is rolled back.
    private func removeChildren(_ item: CleanupItem, live: borrowing LiveTarget, expected: FileIdentity,
                                tree: StorageTree, journal: StagingJournal, outcome: CleanItemOutcome, index: Int,
                                run: Run) -> CleanItemOutcome {
        var outcome = outcome
        guard live.identity == expected, live.identity.isDirectory else {
            outcome.skip = .changedSinceScan
            return outcome
        }
        do {
            let dir = try FileDescriptor.open(at: live.parent.rawValue, live.leaf,
                                              flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            // Same directory as the one checked: it could have been swapped between the two opens.
            guard try dir.identity() == expected else {
                outcome.skip = .changedSinceScan
                return outcome
            }
            let listing = try CleanFS.list(dirFd: dir.rawValue)
            return removeListed(listing, in: dir.rawValue, item: item, expected: expected, tree: tree,
                                journal: journal, outcome: outcome, index: index, run: run)
        } catch {
            return skipped(outcome, CleanFS.skipReason(for: error))
        }
    }

    private func removeListed(_ listing: (names: [String], unrepresentable: Int), in dirFd: Int32,
                              item: CleanupItem, expected: FileIdentity, tree: StorageTree,
                              journal: StagingJournal, outcome: CleanItemOutcome, index: Int,
                              run: Run) -> CleanItemOutcome {
        var outcome = outcome
        // Child bytes: the tree's size when the child is a scanned node still matching the live inode, else the
        // live allocated size (`st_blocks * 512`, directories walked).
        var nodes: [String: StorageNodeID] = [:]
        if let parentNode = item.nodeID {
            for child in tree.sortedChildren(parentNode) { nodes[tree.name(child)] = child }
        }
        outcome.skippedChildren = listing.unrepresentable
        for (i, name) in listing.names.enumerated() {
            guard let st = try? CleanFS.statAt(dirFd, name) else {
                outcome.skippedChildren += 1
                continue
            }
            let childIdentity = FileIdentity(st)
            // The name maps to a node either way (the UI hides it); the tree's size only describes the same inode.
            let node = nodes[name]
            let scannedSize = node.flatMap { tree.identity($0) == childIdentity ? tree.size($0) : nil }
            let bytes = scannedSize ?? CleanFS.allocatedBytes(dirFd: dirFd, name: name)
            let result = detach(parent: dirFd, parentPath: item.path, parentIdentity: expected, leaf: name,
                                expected: childIdentity, bytes: bytes, journal: journal, index: index, run: run,
                                clearImmutable: false)
            switch result {
            case .committed:
                outcome.committedChildren += 1
                outcome.detachedBytes += bytes
                if let node { outcome.removedNodes.append(node) }
            case .cancelled:
                outcome.skippedChildren += listing.names.count - i
                run.acc.withLock { $0.sawCancel = true }
                outcome.partial = outcome.committedChildren > 0
                outcome.skip = outcome.committedChildren == 0 ? .cancelled : nil
                return outcome
            case let .skipped(reason):
                // A child that vanished since the listing is already gone: nothing to keep or report.
                if reason != .vanished { outcome.skippedChildren += 1 }
            }
        }
        outcome.partial = outcome.skippedChildren > 0 && outcome.committedChildren > 0
        context.log.notice("detached \(outcome.committedChildren) children of \(item.path, privacy: .public), \(outcome.detachedBytes) bytes, mode remove")
        return outcome
    }

    private enum Detached {
        case committed
        case cancelled
        case skipped(SkipReason)
    }

    /// Takes a worker slot, runs the journal for one entry and hands a committed entry to the delete pool.
    private func detach(parent: Int32, parentPath: String, parentIdentity: FileIdentity, leaf: String,
                        expected: FileIdentity, bytes: UInt64, journal: StagingJournal, index: Int, run: Run,
                        clearImmutable: Bool) -> Detached {
        run.slots.wait()
        if isCancelled() {
            run.slots.signal()
            return .cancelled
        }
        let result = journal.detach(parent: parent, parentPath: parentPath, parentIdentity: parentIdentity,
                                    leaf: leaf, expected: expected, clearImmutable: clearImmutable)
        switch result {
        case let .skipped(reason, leftover):
            run.slots.signal()
            if leftover { run.acc.withLock { $0.leftovers += 1 } }
            return .skipped(reason)
        case let .committed(entry):
            run.group.enter()
            let deleter = context.deleter
            let log = context.log
            deletePool.async {
                let target = DeleteTarget(commitFd: journal.commit.rawValue, commitPath: journal.commitPath,
                                          name: entry.name)
                let deleted = deleter.delete(target, clearImmutable: clearImmutable)
                if deleted.removed {
                    run.acc.withLock { $0.freed += bytes }
                    run.continuation.yield(.freed(bytes))
                } else {
                    // Residual files: nothing is credited, the entry stays in commit/ for the launch sweep.
                    run.acc.withLock { _ = $0.partial.insert(index) }
                    log.error("delete of \(leaf, privacy: .public) left files: \(deleted.failures.joined(separator: "; "), privacy: .public)")
                }
                run.slots.signal()
                run.group.leave()
            }
            return .committed
        }
    }

    // MARK: - Empty Trash

    private func runEmptyTrash(run: Run) {
        let trashPath = context.home + "/.Trash"
        let root: TrustedRoot
        do {
            root = try TrustedRoot(path: trashPath)
        } catch {
            // No Trash folder = nothing to empty.
            if error.errno != ENOENT {
                run.record(CleanItemOutcome(itemID: 0, skip: CleanFS.skipReason(for: error)), at: 0)
            }
            return
        }
        // `TrustedRoot` resolves the root's own spelling; a `.Trash` that is a symlink would empty some other folder.
        guard root.canonicalPath == trashPath else {
            run.record(CleanItemOutcome(itemID: 0, skip: .denied(.unverifiable)), at: 0)
            return
        }
        do {
            let journal = try staging.openJournal(hooks: hooks)
            try root.withDescriptor { (dirFd: Int32) throws(SafePathError) in
                let listing = try CleanFS.list(dirFd: dirFd)
                emptyTrash(listing.names, in: dirFd, trashPath: trashPath, trashIdentity: root.identity,
                           journal: journal, run: run)
            }
        } catch {
            run.record(CleanItemOutcome(itemID: 0, skip: CleanFS.skipReason(for: error)), at: 0)
        }
    }

    private func emptyTrash(_ names: [String], in dirFd: Int32, trashPath: String, trashIdentity: FileIdentity,
                            journal: StagingJournal, run: Run) {
        for (index, name) in names.enumerated() {
            hooks.beforeItem?(index)
            let id = Int32(truncatingIfNeeded: index)
            if isCancelled() {
                run.acc.withLock { $0.sawCancel = true }
                run.record(CleanItemOutcome(itemID: id, skip: .cancelled), at: index)
                continue
            }
            guard let st = try? CleanFS.statAt(dirFd, name) else {
                run.record(CleanItemOutcome(itemID: id, skip: .vanished), at: index)
                continue
            }
            let bytes = CleanFS.allocatedBytes(dirFd: dirFd, name: name)
            var outcome = CleanItemOutcome(itemID: id)
            switch detach(parent: dirFd, parentPath: trashPath, parentIdentity: trashIdentity, leaf: name,
                          expected: FileIdentity(st), bytes: bytes, journal: journal, index: index, run: run,
                          clearImmutable: true) {
            case .committed:
                outcome.detachedBytes = bytes
                context.log.notice("emptied \(trashPath + "/" + name, privacy: .public), \(bytes) bytes, mode remove")
            case .cancelled:
                outcome.skip = .cancelled
                run.acc.withLock { $0.sawCancel = true }
            case let .skipped(reason):
                outcome.skip = reason
            }
            run.record(outcome, at: index)
        }
    }
}
