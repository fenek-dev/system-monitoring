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

/// The only code that deletes or moves user files.
///
/// Detaching is serial (journal rename, Trash, evict) and deleting is a pool of at most `maxInFlight` workers. The
/// detach loop waits for a free worker slot before taking the next item, so after `cancel()` at most that many
/// committed entries are left to drain, and a crash leaves few entries for the launch sweep.
///
/// Every run (`clean`, `emptyTrash`) owns its cancellation token, slots and accounting; `cancel()` cancels the runs
/// that are active at that moment, so a run started afterwards is never affected.
public final class Cleaner: Sendable {
    static let maxInFlight = 4

    private let context: CleanContext
    private let hooks: CleanTestHooks
    private let staging: Staging
    private let activeRuns = Mutex<[ObjectIdentifier: Run]>([:])
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

    /// Stops detaching further items in every active run. Entries already committed keep deleting; each stream
    /// still ends with exactly one `.finished`. A run started after this call is not cancelled.
    public func cancel() {
        let runs = activeRuns.withLock { Array($0.values) }
        for run in runs { run.cancel() }
    }

    /// App quit: aborts deletions in flight and refuses new ones. Their entries stay in `commit/` for the next
    /// launch sweep.
    public func abortDeletes() {
        context.deleter.cancelInFlight()
    }

    public func clean(_ items: [CleanupItem], tree: StorageTree,
                      overlay: StorageTreeOverlay) -> AsyncStream<CleanEvent> {
        start { run in self.runClean(items, tree: tree, overlay: overlay, run: run) }
    }

    /// Journal-removes every child of `~/.Trash`. Entries owned by the user with `uchg` are unlocked first.
    public func emptyTrash() -> AsyncStream<CleanEvent> {
        start { run in self.runEmptyTrash(run: run) }
    }

    /// The run is registered before this returns, so a `cancel()` right after the call is not lost.
    private func start(_ body: @escaping @Sendable (Run) -> Void) -> AsyncStream<CleanEvent> {
        let (stream, continuation) = AsyncStream<CleanEvent>.makeStream()
        let run = Run(continuation: continuation)
        let key = ObjectIdentifier(run)
        activeRuns.withLock { $0[key] = run }
        detachQueue.async { [self] in
            body(run)
            run.finish()
            activeRuns.withLock { _ = $0.removeValue(forKey: key) }
        }
        return stream
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
        /// Items whose `.item` event went out; a `.freed` for any other item waits (`.item` always comes first).
        var emitted: Set<Int> = []
        var deferredFreed: [Int: [UInt64]] = [:]
    }

    /// Hard-linked files in deleted entries: a file's bytes are credited once, when the run has removed its last link.
    private struct LinkLedger: Sendable {
        var removed: [FileIdentity: Int] = [:]
        var credited: Set<FileIdentity> = []
    }

    private final class Run: Sendable {
        let continuation: AsyncStream<CleanEvent>.Continuation
        let slots = DispatchSemaphore(value: Cleaner.maxInFlight)
        let group = DispatchGroup()
        let acc = Mutex(Accumulator())
        let cancelFlag = Mutex(false)
        private let ledger = Mutex(LinkLedger())

        init(continuation: AsyncStream<CleanEvent>.Continuation) {
            self.continuation = continuation
        }

        var isCancelled: Bool { cancelFlag.withLock { $0 } }

        func cancel() { cancelFlag.withLock { $0 = true } }

        func noteCancelled() { acc.withLock { $0.sawCancel = true } }

        func record(_ outcome: CleanItemOutcome, at index: Int) {
            acc.withLock { acc in
                acc.outcomes[index] = outcome
                continuation.yield(.item(outcome))
                acc.emitted.insert(index)
                for bytes in acc.deferredFreed.removeValue(forKey: index) ?? [] {
                    continuation.yield(.freed(bytes))
                }
            }
        }

        /// Credits bytes that are gone for good. The event waits until its item's `.item` went out.
        func freed(_ bytes: UInt64, item index: Int) {
            acc.withLock { acc in
                acc.freed += bytes
                if acc.emitted.contains(index) {
                    continuation.yield(.freed(bytes))
                } else {
                    acc.deferredFreed[index, default: []].append(bytes)
                }
            }
        }

        /// Bytes of hard-linked files whose last link this run just removed (each file once).
        func linkCredit(_ links: [FileIdentity: CleanFS.LinkSeen]) -> UInt64 {
            ledger.withLock { ledger in
                var credit: UInt64 = 0
                for (identity, seen) in links {
                    let removed = (ledger.removed[identity] ?? 0) + seen.occurrences
                    ledger.removed[identity] = removed
                    if UInt64(removed) >= seen.linkCount, ledger.credited.insert(identity).inserted {
                        credit += seen.bytes
                    }
                }
                return credit
            }
        }

        func finish() {
            // Detaching stopped; wait for every committed entry to be deleted before the single `.finished`.
            group.wait()
            let report = acc.withLock { acc -> CleanReport in
                var outcomes = acc.outcomes.sorted { $0.key < $1.key }.map(\.value)
                let indices = acc.outcomes.keys.sorted()
                for (position, index) in indices.enumerated() where acc.partial.contains(index) {
                    outcomes[position].partial = true
                }
                return CleanReport(freedBytes: acc.freed, trashedBytes: acc.trashed, evictedBytes: acc.evicted,
                                   outcomes: outcomes, cancelled: acc.sawCancel, stagingLeftovers: acc.leftovers,
                                   undo: acc.undo.isEmpty ? nil : UndoRecord(date: Date(), entries: acc.undo))
            }
            continuation.yield(.finished(report))
            continuation.finish()
        }
    }

    /// What a clean run needs besides the live checks done per mutation.
    private struct Setup {
        var denylist: Denylist
        var journal: Result<StagingJournal, SafePathError>
    }

    // MARK: - Clean

    private func runClean(_ items: [CleanupItem], tree: StorageTree, overlay: StorageTreeOverlay, run: Run) {
        let touchesFiles: (CleanupItem) -> Bool = { [.remove, .trash, .evict].contains($0.mode) }
        let journal: Result<StagingJournal, SafePathError>
        if items.contains(where: { $0.mode == .remove }) {
            do { journal = .success(try staging.openJournal(hooks: hooks)) } catch { journal = .failure(error) }
        } else {
            journal = .failure(.invalidPath("journal not needed"))
        }
        let denylist = Denylist.build(home: context.home, scanRoot: tree.root.path,
                                      dataDirectories: context.dataDirectories)
        let setup = Setup(denylist: denylist, journal: journal)
        let held = context.inUse?.inUse(items.filter(touchesFiles)) ?? []

        for (index, item) in items.enumerated() {
            hooks.beforeItem?(index)
            if run.isCancelled {
                run.noteCancelled()
                run.record(CleanItemOutcome(itemID: item.id, skip: .cancelled), at: index)
                continue
            }
            let outcome = process(item, index: index, tree: tree, overlay: overlay, setup: setup,
                                  inUse: held.contains(item.id), run: run)
            run.record(outcome, at: index)
        }
    }

    private func process(_ item: CleanupItem, index: Int, tree: StorageTree, overlay: StorageTreeOverlay,
                         setup: Setup, inUse: Bool, run: Run) -> CleanItemOutcome {
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
                run.freed(bytes, item: index)
            case let .failed(message):
                outcome.skip = .failed(message)
            }
            return outcome
        case .remove, .trash, .evict:
            break
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

        switch item.mode {
        case .trash:
            return trash(item, expected: expected, bytes: bytes, setup: setup, outcome: outcome, run: run)
        case .evict:
            return evict(item, expected: expected, bytes: bytes, setup: setup, outcome: outcome, run: run)
        default:
            break
        }

        guard case let .success(journal) = setup.journal else {
            outcome.skip = .failed("staging unavailable")
            return outcome
        }
        if item.keepParent {
            return removeChildren(item, expected: expected, tree: tree, setup: setup, journal: journal,
                                  outcome: outcome, index: index, run: run)
        }
        return removeWhole(item, expected: expected, bytes: bytes, setup: setup, journal: journal,
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

    // MARK: - Live authorization

    private enum Authorized<R> {
        case ok(R)
        case refused(SkipReason)
    }

    /// Opens `path` fresh (new `TrustedRoot`, no-follow fd-relative walk) and checks the walked ancestors and the
    /// target against the run's denylist by identity and by component spelling, then calls `body` while the check
    /// still holds. Called immediately before every mutation, after any slot wait: the ancestors, the root itself
    /// and the protected directories can all have been replaced since the run started or since the scan. Only the
    /// opens and set lookups happen here; the denylist itself is built once per run.
    private func authorize<R>(_ path: String, root rootPath: String? = nil, setup: Setup,
                              _ body: (borrowing LiveTarget, Denylist) -> R) -> Authorized<R> {
        let live: LiveTarget
        do {
            let root = try TrustedRoot(path: rootPath ?? context.permittedRoot)
            live = try LiveTarget.open(root: root, absolutePath: path)
        } catch {
            return .refused(CleanFS.skipReason(for: error))
        }
        if let reason = setup.denylist.check(live: live) { return .refused(.denied(reason)) }
        return .ok(body(live, setup.denylist))
    }

    // MARK: - Trash / evict

    private enum TrashAttempt {
        case trashed(String)
        case changed
        case failed(TrashError)
    }

    private func trash(_ item: CleanupItem, expected: FileIdentity, bytes: UInt64, setup: Setup,
                       outcome: CleanItemOutcome, run: Run) -> CleanItemOutcome {
        var outcome = outcome
        let attempt = authorize(item.path, setup: setup) { live, _ -> TrashAttempt in
            guard live.identity == expected else { return .changed }
            do throws(TrashError) {
                // Accepted window: `trashItem` takes a URL, so the path is resolved again after the identity check
                // above. The system writes the Put Back metadata, which is why we don't rename into `.Trash`.
                return .trashed(try context.trash.trash(path: item.path))
            } catch {
                return .failed(error)
            }
        }
        let resulting: String
        switch attempt {
        case let .refused(reason):
            return reason == .vanished ? vanished(item, outcome) : skipped(outcome, reason)
        case .ok(.changed):
            return skipped(outcome, .changedSinceScan)
        case let .ok(.failed(error)):
            switch error {
            case .noTrash: outcome.skip = .noTrash
            case .vanished: outcome.skip = .vanished
            case let .failed(message): outcome.skip = .failed(message)
            }
            return outcome
        case let .ok(.trashed(path)):
            resulting = path
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

    /// Where the item landed and proof that it is the inode we trashed, for a safe undo later. Anything else (a
    /// replacement under that name, a missing entry) gets no undo entry: the item is in the Trash (the user can Put
    /// Back), but the app must never "undo" by moving something it didn't trash.
    private func undoEntry(_ item: CleanupItem, expected: FileIdentity, resulting: String) -> UndoEntry? {
        let parentPath = (resulting as NSString).deletingLastPathComponent
        do {
            let trashRoot = try TrustedRoot(path: parentPath)
            let rel = try trashRoot.relativePath(of: resulting)
            guard rel.components.count == 1 else { throw SafePathError.outsideRoot }
            let landed = trashRoot.withDescriptor { CleanFS.identity(of: rel.leaf, in: $0) }
            guard landed == expected else {
                context.log.error("trash: \(resulting, privacy: .public) is not the inode that was trashed; no undo record")
                return nil
            }
            return UndoEntry(itemID: item.id, nodeID: item.nodeID, originalPath: item.path, trashPath: resulting,
                             identity: expected, trashParentPath: parentPath,
                             trashParentIdentity: trashRoot.identity)
        } catch {
            context.log.error("trash: no undo record for \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private enum EvictAttempt {
        case evicted
        case changed
        case failed(EvictError)
    }

    private func evict(_ item: CleanupItem, expected: FileIdentity, bytes: UInt64, setup: Setup,
                       outcome: CleanItemOutcome, run: Run) -> CleanItemOutcome {
        var outcome = outcome
        let attempt = authorize(item.path, setup: setup) { live, _ -> EvictAttempt in
            guard live.identity == expected else { return .changed }
            do throws(EvictError) {
                // Accepted window: `evictUbiquitousItem` takes a URL, resolved again after the identity check.
                try context.evictor.evict(path: item.path)
                return .evicted
            } catch {
                return .failed(error)
            }
        }
        switch attempt {
        case let .refused(reason):
            return reason == .vanished ? vanished(item, outcome) : skipped(outcome, reason)
        case .ok(.changed):
            return skipped(outcome, .changedSinceScan)
        case let .ok(.failed(error)):
            return skipped(outcome, .failed("evict: \(error)"))
        case .ok(.evicted):
            break
        }
        outcome.detachedBytes = bytes
        context.log.notice("evicted \(item.path, privacy: .public), \(bytes) bytes, mode evict")
        run.acc.withLock { $0.evicted += bytes }
        return outcome
    }

    // MARK: - Remove

    private func removeWhole(_ item: CleanupItem, expected: FileIdentity, bytes: UInt64, setup: Setup,
                             journal: StagingJournal, outcome: CleanItemOutcome, index: Int,
                             run: Run) -> CleanItemOutcome {
        var outcome = outcome
        let parentPath = (item.path as NSString).deletingLastPathComponent
        let result = detach(journal: journal, bytes: bytes, links: [:], index: index, run: run,
                            clearImmutable: false) {
            authorize(item.path, setup: setup) { live, _ in
                journal.detach(parent: live.parent.rawValue, parentPath: parentPath,
                               parentIdentity: live.parentIdentity, leaf: live.leaf, expected: expected)
            }
        }
        switch result {
        case .committed:
            outcome.detachedBytes = bytes
            outcome.removedNodes = item.nodeID.map { [$0] } ?? []
            context.log.notice("detached \(item.path, privacy: .public), \(bytes) bytes, mode remove")
        case .cancelled:
            outcome.skip = .cancelled
        case let .blocked(reason), let .skipped(reason):
            if reason == .vanished { return vanished(item, outcome) }
            outcome.skip = reason
        }
        return outcome
    }

    /// Keep-parent: the directory stays; each child is read from the live listing and detached on its own, so a
    /// child created after the scan is handled and one replaced after the listing is rolled back. Each child is
    /// authorized again right before its move.
    private func removeChildren(_ item: CleanupItem, expected: FileIdentity, tree: StorageTree, setup: Setup,
                                journal: StagingJournal, outcome: CleanItemOutcome, index: Int,
                                run: Run) -> CleanItemOutcome {
        // Initial open: item-level checks and the live listing. Per-child authorization happens in `detach`.
        let opened = authorize(item.path, setup: setup) { live, _ -> Result<OpenedDirectory?, SafePathError> in
            guard live.identity == expected, live.identity.isDirectory else { return .success(nil) }
            do throws(SafePathError) {
                let dir = try FileDescriptor.open(at: live.parent.rawValue, live.leaf,
                                                  flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                // Same directory as the one checked: it could have been swapped between the two opens.
                guard try dir.identity() == expected else { return .success(nil) }
                let listing = try CleanFS.list(dirFd: dir.rawValue)
                return .success(OpenedDirectory(fd: dir.take(), names: listing.names,
                                                unrepresentable: listing.unrepresentable))
            } catch {
                return .failure(error)
            }
        }
        switch opened {
        case let .refused(reason):
            return reason == .vanished ? vanished(item, outcome) : skipped(outcome, reason)
        case .ok(.success(nil)):
            return skipped(outcome, .changedSinceScan)
        case let .ok(.failure(error)):
            return skipped(outcome, CleanFS.skipReason(for: error))
        case let .ok(.success(directory?)):
            return removeListed(directory, item: item, expected: expected, tree: tree, setup: setup, journal: journal,
                                outcome: outcome, index: index, run: run)
        }
    }

    /// The item directory opened once (owned by `removeListed`) with its live listing.
    private struct OpenedDirectory {
        var fd: Int32
        var names: [String]
        var unrepresentable: Int
    }

    private func removeListed(_ opened: OpenedDirectory, item: CleanupItem,
                              expected: FileIdentity, tree: StorageTree, setup: Setup, journal: StagingJournal,
                              outcome: CleanItemOutcome, index: Int, run: Run) -> CleanItemOutcome {
        var outcome = outcome
        let listing = (names: opened.names, unrepresentable: opened.unrepresentable)
        let dirFd = opened.fd
        defer { close(dirFd) }
        var nodes: [String: StorageNodeID] = [:]
        if let parentNode = item.nodeID {
            for child in tree.sortedChildren(parentNode) { nodes[tree.name(child)] = child }
        }
        outcome.skippedChildren = listing.unrepresentable
        // The directory is held open for the whole loop; `authorize` re-checks per child that the path still names it.

        for (i, name) in listing.names.enumerated() {
            guard let st = try? CleanFS.statAt(dirFd, name) else {
                outcome.skippedChildren += 1
                continue
            }
            let childIdentity = FileIdentity(st)
            // The name maps to a node either way (the UI hides it); the tree's size only describes the same inode.
            let node = nodes[name]
            let scannedSize = node.flatMap { tree.identity($0) == childIdentity ? tree.size($0) : nil }
            let live = scannedSize == nil ? CleanFS.liveSize(dirFd: dirFd, name: name) : CleanFS.LiveSize()
            let bytes = scannedSize ?? live.bytes
            let result = detach(journal: journal, bytes: bytes, links: live.links, index: index, run: run,
                                clearImmutable: false) {
                authorize(item.path, setup: setup) { target, denylist -> DetachResult in
                    // The listed directory must still be what the path names, and the child must not be (or hold)
                    // anything protected under the directory as it is now.
                    guard target.identity == expected else { return .skipped(.changedSinceScan, leftover: false) }
                    if let reason = denylist.check(chain: target.chain + [childIdentity])
                        ?? denylist.check(components: target.components + [name]) {
                        return .skipped(.denied(reason), leftover: false)
                    }
                    return journal.detach(parent: dirFd, parentPath: item.path, parentIdentity: expected, leaf: name,
                                          expected: childIdentity)
                }
            }
            switch result {
            case .committed:
                outcome.committedChildren += 1
                outcome.detachedBytes += bytes
                if let node { outcome.removedNodes.append(node) }
            case .cancelled:
                outcome.skippedChildren += listing.names.count - i
                outcome.partial = outcome.committedChildren > 0
                outcome.skip = outcome.committedChildren == 0 ? .cancelled : nil
                return outcome
            case let .blocked(reason):
                // The directory itself can't be authorized any more: nothing else will be either.
                outcome.skippedChildren += listing.names.count - i
                outcome.partial = outcome.committedChildren > 0
                outcome.skip = outcome.committedChildren == 0 ? reason : nil
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
        /// Authorization of the target failed (denied, vanished, replaced path): item-level, nothing was moved.
        case blocked(SkipReason)
        /// The journal skipped this entry.
        case skipped(SkipReason)
    }

    /// Takes a worker slot, runs `attempt` (authorize + journal) and hands a committed entry to the delete pool.
    private func detach(journal: StagingJournal, bytes: UInt64, links: [FileIdentity: CleanFS.LinkSeen], index: Int,
                        run: Run, clearImmutable: Bool,
                        _ attempt: () -> Authorized<DetachResult>) -> Detached {
        hooks.beforeSlotWait?(index)
        run.slots.wait()
        if run.isCancelled {
            run.slots.signal()
            run.noteCancelled()
            return .cancelled
        }
        switch attempt() {
        case let .refused(reason):
            run.slots.signal()
            return .blocked(reason)
        case let .ok(.skipped(reason, leftover)):
            run.slots.signal()
            if leftover { run.acc.withLock { $0.leftovers += 1 } }
            return .skipped(reason)
        case let .ok(.committed(entry)):
            run.group.enter()
            let deleter = context.deleter
            let log = context.log
            deletePool.async {
                let target = DeleteTarget(commitFd: journal.commit.rawValue, commitPath: journal.commitPath,
                                          name: entry.name)
                let deleted = deleter.delete(target, clearImmutable: clearImmutable)
                if deleted.removed {
                    if clearImmutable { journal.releaseUnlockMarker(entry.name) }
                    run.freed(bytes + run.linkCredit(links), item: index)
                } else {
                    // Residual files: nothing is credited, the entry stays in commit/ for the launch sweep.
                    run.acc.withLock { _ = $0.partial.insert(index) }
                    log.error("delete of \(entry.name, privacy: .public) left files: \(deleted.failures.joined(separator: "; "), privacy: .public)")
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
                run.record(CleanItemOutcome(itemID: 0, skip: CleanFS.skipReason(for: error), path: trashPath), at: 0)
            }
            return
        }
        // `TrustedRoot` resolves the root's own spelling; a `.Trash` that is a symlink would empty some other folder.
        guard root.canonicalPath == trashPath else {
            run.record(CleanItemOutcome(itemID: 0, skip: .denied(.unverifiable), path: trashPath), at: 0)
            return
        }
        do {
            let journal = try staging.openJournal(hooks: hooks)
            let denylist = Denylist.build(home: context.home, scanRoot: context.home,
                                          dataDirectories: context.dataDirectories)
            let setup = Setup(denylist: denylist, journal: .success(journal))
            try root.withDescriptor { (dirFd: Int32) throws(SafePathError) in
                let listing = try CleanFS.list(dirFd: dirFd)
                emptyTrash(listing.names, in: dirFd, trashPath: trashPath, trashIdentity: root.identity,
                           journal: journal, setup: setup, run: run)
            }
        } catch {
            run.record(CleanItemOutcome(itemID: 0, skip: CleanFS.skipReason(for: error), path: trashPath), at: 0)
        }
    }

    private func emptyTrash(_ names: [String], in dirFd: Int32, trashPath: String, trashIdentity: FileIdentity,
                            journal: StagingJournal, setup: Setup, run: Run) {
        for (index, name) in names.enumerated() {
            hooks.beforeItem?(index)
            let id = Int32(truncatingIfNeeded: index)
            let entryPath = trashPath + "/" + name
            if run.isCancelled {
                run.noteCancelled()
                run.record(CleanItemOutcome(itemID: id, skip: .cancelled, path: entryPath), at: index)
                continue
            }
            guard let st = try? CleanFS.statAt(dirFd, name) else {
                run.record(CleanItemOutcome(itemID: id, skip: .vanished, path: entryPath), at: index)
                continue
            }
            let live = CleanFS.liveSize(dirFd: dirFd, name: name)
            var outcome = CleanItemOutcome(itemID: id, path: entryPath)
            // Resolved again from the home folder for every entry: `.Trash` may have been renamed away (into
            // Library/Mail, say) and re-created since the listing, in which case this is not the folder we listed.
            switch detach(journal: journal, bytes: live.bytes, links: live.links, index: index, run: run,
                          clearImmutable: true, {
                authorize(entryPath, root: context.home, setup: setup) { target, _ -> DetachResult in
                    guard target.parentIdentity == trashIdentity else {
                        return .skipped(.changedSinceScan, leftover: false)
                    }
                    return journal.detach(parent: target.parent.rawValue, parentPath: trashPath,
                                          parentIdentity: trashIdentity, leaf: name, expected: FileIdentity(st),
                                          clearImmutable: true)
                }
            }) {
            case .committed:
                outcome.detachedBytes = live.bytes
                context.log.notice("emptied \(entryPath, privacy: .public), \(live.bytes) bytes, mode remove")
            case .cancelled:
                outcome.skip = .cancelled
            case let .blocked(reason), let .skipped(reason):
                outcome.skip = reason
            }
            run.record(outcome, at: index)
        }
    }
}
