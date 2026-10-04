import Foundation
import MonitorModel
import os
import Synchronization

/// Composes scan → classify → resolve → private sizes → cache, and the cleaner, behind one object (spec §3.1, §3.4,
/// §3.5). No AppKit: running apps and app lookups arrive through `StoragePlatform`.
///
/// Heavy synchronous steps (classify, installed apps, Spotlight, private sizes, cache IO) run one at a time on a
/// serial `.utility` queue so they never compete with the walk's threads or with each other.
///
/// Generation: bumped by every scan and by `release()`. Each async step captures the value it started under and
/// drops its result when the engine has moved on, so a late classification can never resurrect a released tree.
public final class StorageEngine: Sendable {
    /// Everything the engine touches outside itself; tests replace single fields of `.live(…)`.
    public struct Environment: Sendable {
        public var home: String
        /// Scan cache, undo store, staging directory live here.
        public var dataDirectory: URL
        public var platform: StoragePlatform
        public var scanner: @Sendable (ScanRoot, ScanAccessPolicy) -> Scanner
        public var sizer: @Sendable (ScanRoot) -> PrivateSizer
        /// Resolved before every scan; inconclusive counts as not granted (the walk would block on TCC prompts).
        public var scanAccess: @Sendable () -> ScanAccessPolicy
        public var classifier: Classifier
        public var installedApps: @Sendable () -> InstalledAppSet
        public var lastUsed: @Sendable (_ root: String, _ minBytes: UInt64) -> [String: Date]
        public var volumeUUID: @Sendable (ScanRoot) -> UUID?
        /// Receives the probe result of the SLIM flag and returns the deleter used for staging and cleaning.
        public var deleter: @Sendable (_ slim: Bool) -> any Deleter
        public var trash: any TrashMover
        public var evictor: any Evictor
        public var simctl: any SimctlRunner
        public var processes: any ProcessPathSource
        /// Banner state; unlike the scan policy, an inconclusive probe reads as granted (no nag for users who
        /// never used Safari).
        public var fullDiskAccess: @Sendable () -> Bool
        public var roots: @Sendable () -> [ScanRoot]
        public var now: @Sendable () -> Date

        public static func live(home: String, dataDirectory: URL, platform: StoragePlatform) -> Environment {
            Environment(
                home: home, dataDirectory: dataDirectory, platform: platform,
                scanner: { root, access in
                    Scanner(lister: BulkLister(rootPath: root.path), threads: Scanner.defaultThreadCount(),
                            home: home, access: access)
                },
                sizer: { root in
                    PrivateSizer(lister: BulkLister(rootPath: root.path, includePrivateSize: true), rootPath: root.path)
                },
                scanAccess: { ScanAccessPolicy(fullDiskAccess: FullDiskAccessProbe.status(home: home) == .granted) },
                classifier: Classifier(home: home, dataDirectories: [dataDirectory.path], git: LiveGitTracking(),
                                       devTools: LiveDevToolProbe(), isUbiquitous: Self.isUbiquitous),
                installedApps: { InstalledAppSet.build(home: home, mdfind: InstalledAppSet.liveMdfind) },
                lastUsed: { SpotlightLastUsed.query(root: $0, minBytes: $1) },
                volumeUUID: Self.volumeUUID,
                deleter: { DeleteWorker(slim: $0) },
                trash: SystemTrashMover(), evictor: UbiquitousEvictor(), simctl: ProcessSimctlRunner(),
                processes: LiveProcessPathSource(),
                fullDiskAccess: { FullDiskAccessProbe.check(home: home) },
                roots: { ScanRoots.available() },
                now: { Date() })
        }

        /// The key `ScanCache` was saved under: the same lookup the scanner reports as `ScanRootInfo.volumeUUID`.
        static func volumeUUID(_ root: ScanRoot) -> UUID? {
            let lister = BulkLister(rootPath: root.path)
            do {
                let info = try lister.rootInfo()
                lister.release()
                return info.volumeUUID
            } catch {
                DiskTools.log.error("cache lookup: root \(root.path, privacy: .public) unreadable: \(error.op, privacy: .public) errno \(error.errno)")
                return nil
            }
        }

        /// Only decides evict vs Trash for Large & Old files; a failed lookup falls back to Trash (reversible).
        static func isUbiquitous(_ path: String) -> Bool {
            do {
                return try URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey])
                    .isUbiquitousItem ?? false
            } catch {
                DiskTools.log.error("iCloud lookup failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// What the engine holds for the open root.
    public struct Current: Sendable {
        public var root: ScanRoot
        public var tree: StorageTree
        public var overlay: StorageTreeOverlay
        public var set: CleanupSet?
    }

    private struct Sized: Sendable {
        var privateBytes: UInt64?
        var provenance: SizeProvenance
    }

    private struct Spotlight: Sendable {
        var minBytes: UInt64
        var map: [String: Date]
    }

    private struct State: Sendable {
        var generation: UInt64 = 0
        /// Generation of the scan the user cancelled; later steps of that scan stop.
        var cancelledScan: UInt64?
        var scanner: Scanner?
        var current: Current?
        var installed: InstalledAppSet?
        var spotlight: Spotlight?
        var sizes: [String: Sized] = [:]
        var linkGroupSizes: [Int32: LinkGroupSize] = [:]
        var sizing: Task<CleanupSet?, Never>?
        var sizingFinal = false
        var cleaners: [String: Cleaner] = [:]
        var deleter: (any Deleter)?
        /// Bumped by `cancelClean`; a run still waiting for the launch tasks checks it before it starts.
        var cleanCancelEpoch = 0
    }

    private let env: Environment
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.telltale.storage.engine", qos: .utility)
    private let cache: ScanCache
    private let undoStore: UndoStore
    private let stagingDir: String
    /// Staging sweep, undo prune and the SLIM probe; no clean starts before it ends.
    private let launch = Mutex<Task<Void, Never>?>(nil)

    public init(_ env: Environment) {
        self.env = env
        cache = ScanCache(directory: env.dataDirectory)
        undoStore = UndoStore(file: env.dataDirectory.appendingPathComponent("storage-undo.json").path,
                              permittedRoot: env.home)
        stagingDir = env.dataDirectory.appendingPathComponent("staging").path
        let task = Task.detached(priority: .utility) { [self] in runLaunchTasks() }
        launch.withLock { $0 = task }
    }

    private func runLaunchTasks() {
        do {
            try FileManager.default.createDirectory(
                atPath: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            DiskTools.log.error("staging dir \(self.stagingDir, privacy: .public) not created: \(error.localizedDescription, privacy: .public)")
        }
        let slim = DeleteWorker.slimSupported(scratchIn: stagingDir)
        let deleter = env.deleter(slim)
        let report = Staging(dir: stagingDir, deleter: deleter).sweep()
        DiskTools.log.notice("staging sweep: deleted \(report.deleted) restored \(report.restored) leftovers \(report.leftovers) failures \(report.deleteFailures) slim \(slim)")
        if let error = report.error { DiskTools.log.error("staging sweep: \(error, privacy: .public)") }
        do { try undoStore.prune(now: env.now()) } catch {
            DiskTools.log.error("undo prune failed: \(error.localizedDescription, privacy: .public)")
        }
        state.withLock { $0.deleter = deleter }
    }

    private func awaitLaunch() async {
        await launch.withLock { $0 }?.value
    }

    // MARK: - State

    public func current() -> Current? { state.withLock { $0.current } }

    /// Replaces the held overlay with one that has the cleaning outcomes applied (the next clean starts from it).
    /// False when the held scan is another one than the overlay was made for.
    @discardableResult
    public func replaceOverlay(_ overlay: StorageTreeOverlay) -> Bool {
        state.withLock { state in
            guard state.current?.tree.version == overlay.treeVersion else { return false }
            state.current?.overlay = overlay
            return true
        }
    }

    /// Writes the held overlay beside the cached tree.
    public func saveOverlay() async {
        guard let overlay = current()?.overlay else { return }
        await onQueue { [cache] in
            do { try cache.saveOverlay(overlay) } catch {
                DiskTools.log.error("overlay sidecar not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func isLive(_ gen: UInt64) -> Bool { state.withLock { $0.generation == gen } }

    private func isLiveScan(_ gen: UInt64) -> Bool {
        state.withLock { $0.generation == gen && $0.cancelledScan != gen }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Scan

    public func scan(root: ScanRoot, options: ClassifyOptions) -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self)
        let gen = state.withLock { state -> UInt64 in
            state.generation += 1
            state.scanner?.cancel()
            state.scanner = nil
            state.cancelledScan = nil
            state.sizing = nil
            state.sizingFinal = false
            return state.generation
        }
        Task.detached(priority: .utility) { [self] in
            await runScan(root: root, options: options, gen: gen, continuation: continuation)
            continuation.finish()
        }
        return stream
    }

    public func cancelScan() {
        state.withLock { state in
            state.cancelledScan = state.generation
            state.scanner?.cancel()
        }
    }

    /// Yields only while the scan is still the engine's: check and yield are one step under the lock.
    private func emit(_ event: ScanEvent, gen: UInt64, to continuation: AsyncStream<ScanEvent>.Continuation) {
        state.withLock { state in
            if state.generation == gen { continuation.yield(event) }
        }
    }

    private func runScan(root: ScanRoot, options: ClassifyOptions, gen: UInt64,
                         continuation: AsyncStream<ScanEvent>.Continuation) async {
        let access = await onQueue { [env] in env.scanAccess() }
        let scanner = env.scanner(root, access)
        let started = state.withLock { state -> Bool in
            guard state.generation == gen, state.cancelledScan != gen else { return false }
            state.scanner = scanner
            return true
        }
        guard started else {
            emit(.failed(.cancelled), gen: gen, to: continuation)
            return
        }
        for await event in scanner.scan(root: root, willUnmount: env.platform.willUnmount()) {
            switch event {
            case let .finished(tree):
                let accepted = state.withLock { state -> Bool in
                    guard state.generation == gen else { return false }
                    state.current = Current(root: root, tree: tree, overlay: StorageTreeOverlay(tree: tree), set: nil)
                    state.installed = nil
                    state.spotlight = nil
                    state.sizes = [:]
                    state.linkGroupSizes = [:]
                    state.sizingFinal = false
                    return true
                }
                guard accepted else { return }
                emit(event, gen: gen, to: continuation)
                // Only a finished scan is complete enough to be loaded as truth on the next launch.
                await onQueue { [cache] in
                    do { try cache.save(tree) } catch {
                        DiskTools.log.error("scan cache not saved: \(String(describing: error), privacy: .public)")
                    }
                }
                if root.allowsCleanup {
                    await classifyScanned(tree: tree, root: root, options: options, gen: gen, to: continuation)
                }
                return
            case .failed:
                emit(event, gen: gen, to: continuation)
                return
            default:
                emit(event, gen: gen, to: continuation)
            }
        }
    }

    private func classifyScanned(tree: StorageTree, root: ScanRoot, options: ClassifyOptions, gen: UInt64,
                                 to continuation: AsyncStream<ScanEvent>.Continuation) async {
        let stopped: @Sendable () -> Bool = { [self] in !isLiveScan(gen) }
        guard let (early, resolved) = await classify(tree: tree, options: options, gen: gen, isCancelled: stopped) else {
            cancelledTail(gen: gen, to: continuation)
            return
        }
        emit(.classified(early), gen: gen, to: continuation)
        guard storeSet(resolved, gen: gen) else { return }
        emit(.classified(resolved), gen: gen, to: continuation)
        guard let final = await startSizing(resolved, tree: tree, root: root, gen: gen, isCancelled: stopped).value else {
            cancelledTail(gen: gen, to: continuation)
            return
        }
        guard storeSet(final, gen: gen) else { return }
        emit(.classified(final), gen: gen, to: continuation)
    }

    /// The user cancelled while classifying: the tree is final already, the model keeps it on screen.
    private func cancelledTail(gen: UInt64, to continuation: AsyncStream<ScanEvent>.Continuation) {
        if state.withLock({ $0.generation == gen && $0.cancelledScan == gen }) {
            emit(.failed(.cancelled), gen: gen, to: continuation)
        }
    }

    // MARK: - Classification

    /// Classifies `tree`, then asks the platform about leftover owners. Returns the set before and after resolving
    /// (the first one shows the map's items at once), nil if the engine moved on or `isCancelled`.
    private func classify(tree: StorageTree, options: ClassifyOptions, gen: UInt64,
                          isCancelled: @escaping @Sendable () -> Bool) async -> (CleanupSet, CleanupSet)? {
        let result: ClassifyResult? = await onQueue { [self] in
            guard !isCancelled(), isLive(gen) else { return nil }
            let (installed, lastUsed) = prepareInputs(options: options, gen: gen)
            return env.classifier.classify(tree: tree, installed: installed, lastUsed: lastUsed, options: options)
        }
        guard let result, !isCancelled(), isLive(gen) else { return nil }
        var early = result.set
        await markRunning(&early)
        var found: [String: [String]] = [:]
        for id in result.unresolvedBundleIDs.sorted() {
            found[id] = await env.platform.appPaths(id)
        }
        guard isLive(gen), !isCancelled() else { return nil }
        let classifier = env.classifier
        var resolved = await onQueue { [found] in classifier.resolve(result, found: found) }
        await markRunning(&resolved)
        guard isLive(gen), !isCancelled() else { return nil }
        return (early, resolved)
    }

    /// Installed apps and the Spotlight map are built once per open window (released with it); a lower "old"
    /// threshold than the one the map was queried for asks again.
    private func prepareInputs(options: ClassifyOptions, gen: UInt64) -> (InstalledAppSet, [String: Date]) {
        let (cachedApps, cachedSpotlight) = state.withLock { ($0.installed, $0.spotlight) }
        let installed = cachedApps ?? env.installedApps()
        let spotlight: Spotlight
        if let known = cachedSpotlight, options.oldBytes >= known.minBytes {
            spotlight = known
        } else {
            spotlight = Spotlight(minBytes: options.oldBytes, map: env.lastUsed(env.home, options.oldBytes))
        }
        state.withLock { state in
            guard state.generation == gen else { return }
            state.installed = installed
            state.spotlight = spotlight
        }
        return (installed, spotlight.map)
    }

    /// Badge for items whose owner is running (spec §6.5): their caches are not pre-checked.
    private func markRunning(_ set: inout CleanupSet) async {
        let running = Set(await env.platform.runningBundleIDs().map { $0.lowercased() })
        for index in set.items.indices {
            set.items[index].runningApp = set.items[index].owner.map { running.contains($0.bundleID.lowercased()) }
                ?? false
        }
    }

    private func storeSet(_ set: CleanupSet, gen: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == gen, state.current?.tree.version == set.treeVersion else { return false }
            state.current?.set = set
            return true
        }
    }

    /// Starts the private-size pass; `reclassify` waits for it through `State.sizing`. The result is nil when the
    /// pass was cancelled or the engine moved on.
    private func startSizing(_ set: CleanupSet, tree: StorageTree, root: ScanRoot, gen: UInt64,
                             isCancelled: @escaping @Sendable () -> Bool) -> Task<CleanupSet?, Never> {
        let sizer = env.sizer(root)
        let task = Task<CleanupSet?, Never>(priority: .utility) { [self] in
            let stopped: @Sendable () -> Bool = { isCancelled() || !self.isLive(gen) }
            let output = await onQueue { () -> PrivateSizer.Output? in
                let output = sizer.run(items: set.items, tree: tree, isCancelled: stopped)
                return stopped() ? nil : output
            }
            guard let output else { return nil }
            var final = set
            final.items = output.items
            final.linkGroupSizes = output.linkGroupSizes
            final.privateSizesFinal = true
            let kept = state.withLock { state -> Bool in
                guard state.generation == gen else { return false }
                state.sizes = Dictionary(
                    output.items.map { ($0.path, Sized(privateBytes: $0.privateBytesExcludingLinks,
                                                       provenance: $0.sizeProvenance)) },
                    uniquingKeysWith: { first, _ in first })
                state.linkGroupSizes = output.linkGroupSizes
                state.sizingFinal = true
                return true
            }
            return kept ? final : nil
        }
        state.withLock { if $0.generation == gen { $0.sizing = task } }
        return task
    }

    // MARK: - Cache

    /// The cached scan of `root` classified right away; private sizes continue in the background (`reclassify`
    /// waits for them). Non-cleanup roots get an empty set.
    public func loadCached(root: ScanRoot, options: ClassifyOptions) async
        -> (StorageTree, StorageTreeOverlay, CleanupSet)? {
        let gen = state.withLock { $0.generation }
        let loaded = await onQueue { [self] in
            cache.load(root: root, volumeUUID: env.volumeUUID(root))
        }
        guard let loaded, isLive(gen) else { return nil }
        let (tree, overlay) = (loaded.tree, loaded.overlay)
        var set = CleanupSet(treeVersion: tree.version, items: [], ownershipResolved: true, privateSizesFinal: true,
                             trashBytes: nil)
        if root.allowsCleanup {
            guard let (_, resolved) = await classify(tree: tree, options: options, gen: gen, isCancelled: { false }) else {
                return nil
            }
            set = resolved
        }
        let kept = state.withLock { state -> Bool in
            guard state.generation == gen else { return false }
            state.current = Current(root: root, tree: tree, overlay: overlay, set: set)
            state.sizes = [:]
            state.linkGroupSizes = [:]
            state.sizingFinal = false
            return true
        }
        guard kept else { return nil }
        if root.allowsCleanup { _ = startSizing(set, tree: tree, root: root, gen: gen, isCancelled: { false }) }
        return (tree, overlay, set)
    }

    /// Classifies the held tree again with new thresholds, after any running private-size pass, reusing its
    /// results by path.
    public func reclassify(options: ClassifyOptions) async -> CleanupSet? {
        let (gen, current, sizing) = state.withLock { ($0.generation, $0.current, $0.sizing) }
        guard let current, current.root.allowsCleanup else { return nil }
        _ = await sizing?.value
        guard isLive(gen),
              let (_, resolved) = await classify(tree: current.tree, options: options, gen: gen, isCancelled: { false })
        else { return nil }
        var set = resolved
        let (sizes, linkSizes, sizingFinal) = state.withLock { ($0.sizes, $0.linkGroupSizes, $0.sizingFinal) }
        for index in set.items.indices {
            guard let sized = sizes[set.items[index].path] else { continue }
            set.items[index].privateBytesExcludingLinks = sized.privateBytes
            set.items[index].sizeProvenance = sized.provenance
        }
        set.linkGroupSizes = linkSizes
        set.privateSizesFinal = sizingFinal
        return storeSet(set, gen: gen) ? set : nil
    }

    // MARK: - Release

    /// Window closed: drops the tree and everything derived from it. A running clean keeps its own copies and
    /// drains (spec §3.4).
    public func release() {
        state.withLock { state in
            state.generation += 1
            state.scanner?.cancel()
            state.scanner = nil
            state.current = nil
            state.installed = nil
            state.spotlight = nil
            state.sizes = [:]
            state.linkGroupSizes = [:]
            state.sizing = nil
            state.sizingFinal = false
        }
    }

    // MARK: - Queries

    public func policy() -> StoragePolicy {
        guard let current = current() else { return .none }
        let denylist = Denylist.build(home: env.home, scanRoot: current.root.path,
                                      dataDirectories: [env.dataDirectory.path])
        return denylist.policy(for: current.tree)
    }

    public func checkInUse(_ items: [CleanupItem]) async -> Set<Int32> {
        let checker = InUseChecker(processes: env.processes)
        return await onQueue { checker.inUse(items) }
    }

    public func hasFullDiskAccess() async -> Bool {
        await onQueue { [env] in env.fullDiskAccess() }
    }

    public func availableRoots() -> [ScanRoot] { env.roots() }

    // MARK: - Clean

    public func clean(_ items: [CleanupItem]) -> AsyncStream<CleanEvent> {
        guard let current = current() else {
            DiskTools.log.error("clean requested without a loaded scan")
            return Self.refused(items, reason: "no scan loaded")
        }
        return run(permittedRoot: current.root.path) { cleaner in
            cleaner.clean(items, tree: current.tree, overlay: current.overlay)
        }
    }

    /// Empty Trash acts on `~/.Trash`: always permitted below home, whatever root is open.
    public func emptyTrash() -> AsyncStream<CleanEvent> {
        run(permittedRoot: env.home) { $0.emptyTrash() }
    }

    public func cancelClean() {
        let cleaners = state.withLock { state in
            state.cleanCancelEpoch += 1
            return Array(state.cleaners.values)
        }
        for cleaner in cleaners { cleaner.cancel() }
    }

    public func undo(_ record: UndoRecord) -> AsyncStream<CleanEvent> {
        undoStore.restore(record)
    }

    /// App quit: aborts deletions in flight; their staging entries are finished by the next launch's sweep.
    public func abortDeletes() {
        state.withLock { $0.deleter }?.cancelInFlight()
    }

    private func run(permittedRoot: String, start: @escaping @Sendable (Cleaner) -> AsyncStream<CleanEvent>)
        -> AsyncStream<CleanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CleanEvent.self)
        let epoch = state.withLock { $0.cleanCancelEpoch }
        Task.detached(priority: .userInitiated) { [self] in
            await awaitLaunch()
            let (cleaner, cancelled) = state.withLock { state -> (Cleaner?, Bool) in
                guard let deleter = state.deleter else { return (nil, false) }
                let cancelled = state.cleanCancelEpoch != epoch
                if let known = state.cleaners[permittedRoot] { return (known, cancelled) }
                let cleaner = Cleaner(context: CleanContext(
                    home: env.home, permittedRoot: permittedRoot, stagingDir: stagingDir,
                    dataDirectories: [env.dataDirectory.path], trash: env.trash, deleter: deleter,
                    evictor: env.evictor, simctl: env.simctl, inUse: InUseChecker(processes: env.processes)))
                state.cleaners[permittedRoot] = cleaner
                return (cleaner, cancelled)
            }
            guard let cleaner else {
                DiskTools.log.error("clean refused: launch tasks did not provide a deleter")
                continuation.yield(.finished(CleanReport()))
                continuation.finish()
                return
            }
            let events = start(cleaner)
            if cancelled { cleaner.cancel() }
            for await event in events {
                if case let .finished(report) = event, let record = report.undo {
                    do { try undoStore.append(record) } catch {
                        DiskTools.log.error("undo record not stored: \(error.localizedDescription, privacy: .public)")
                    }
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
        return stream
    }

    private static func refused(_ items: [CleanupItem], reason: String) -> AsyncStream<CleanEvent> {
        AsyncStream { continuation in
            let outcomes = items.map { CleanItemOutcome(itemID: $0.id, skip: .failed(reason)) }
            for outcome in outcomes { continuation.yield(.item(outcome)) }
            continuation.yield(.finished(CleanReport(outcomes: outcomes)))
            continuation.finish()
        }
    }
}
