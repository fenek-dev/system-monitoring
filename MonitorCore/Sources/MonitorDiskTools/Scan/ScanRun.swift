import Darwin
import Foundation
import MonitorModel
import Synchronization

/// What a worker pops: a directory to list, or a package to size without presenting its contents.
struct WalkItem: Sendable {
    enum Kind: Sendable { case directory, package }
    var node: StorageNodeID
    /// Path below the scan root; empty for the root itself.
    var components: [String]
    var kind: Kind
}

/// One scan: workers, queue, arena and event emission. Created and started by `Scanner.scan`.
final class ScanRun: Sendable {
    let root: ScanRoot
    let info: ScanRootInfo
    let lastEventId: UInt64
    private let lister: any DirectoryLister
    private let rules: WalkRules
    private let access: ScanAccessPolicy
    private let progressInterval: Duration
    private let queue: WorkQueue<WalkItem>
    private let builder: Mutex<StorageTreeBuilder>
    private let continuation: AsyncStream<ScanEvent>.Continuation
    private let threadCount: Int

    private let failure = Mutex<ScanFailure?>(nil)
    private let aliveWorkers: Atomic<Int>
    /// True once the terminal event is out: the single gate every publication passes through, so nothing can follow
    /// the terminal event.
    private let closed = Mutex<Bool>(false)
    private let files = Atomic<Int>(0)
    private let bytes = Atomic<UInt64>(0)
    private let currentComponents = Mutex<[String]>([])
    private let helpers = Mutex<[@Sendable () -> Void]>([])

    init(root: ScanRoot, info: ScanRootInfo, lastEventId: UInt64, lister: any DirectoryLister, rules: WalkRules,
         access: ScanAccessPolicy, progressInterval: Duration, threads: Int,
         continuation: AsyncStream<ScanEvent>.Continuation) {
        self.root = root
        self.info = info
        self.lastEventId = lastEventId
        self.lister = lister
        self.rules = rules
        self.access = access
        self.progressInterval = progressInterval
        self.threadCount = threads
        self.queue = WorkQueue(workers: threads)
        self.builder = Mutex(StorageTreeBuilder(root: root, dev: info.dev, volumeUUID: info.volumeUUID,
                                                rootFileID: info.fileID, rootMtime: info.mtime))
        self.continuation = continuation
        self.aliveWorkers = Atomic(threads)
    }

    /// Entries the walk has enumerated so far (kept and folded alike).
    var enumeratedEntries: Int { files.load(ordering: .relaxed) }

    // MARK: - Control

    func start() {
        queue.push([WalkItem(node: 0, components: [], kind: .directory)])
        for index in 0 ..< threadCount {
            let thread = Thread { [self] in worker() }
            thread.name = "telltale.scan.\(index)"
            // Spikes §6: user-initiated threads; a background QoS or GCD queue starves the walk.
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        startTicker()
    }

    /// First failure wins; the stream ends once every worker has left its listing.
    func fail(_ reason: ScanFailure) {
        failure.withLock { if $0 == nil { $0 = reason } }
        queue.cancel()
    }

    /// Cleanup to run when the scan ends (watch sources, helper tasks).
    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        helpers.withLock { $0.append(cleanup) }
    }

    // MARK: - Workers

    private func worker() {
        DatalessPolicy.disableForCurrentThread()
        while let item = queue.pop() {
            currentComponents.withLock { $0 = item.components }
            switch item.kind {
            case .directory: walkDirectory(item)
            case .package: walkPackage(item)
            }
            queue.complete()
        }
        if aliveWorkers.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 { sendTerminal() }
    }

    private func relative(_ components: [String]) throws(ListError) -> RelativePath? {
        guard !components.isEmpty else { return nil }
        do {
            return try RelativePath(components: components)
        } catch {
            throw ListError(error, op: "path \(components.joined(separator: "/"))")
        }
    }

    /// Feeds each batch of one directory to `body`; the handle is closed when this returns.
    private func forEachBatch(_ components: [String], _ body: ([ListedEntry]) -> Void) throws(ListError) {
        let handle = try lister.open(try relative(components))
        while !queue.isCancelled {
            let batch = try lister.list(handle)
            body(batch.entries)
            if batch.done || batch.entries.isEmpty { break }
        }
    }

    private func walkDirectory(_ item: WalkItem) {
        let role = rules.role(of: item.components)
        // Small files are folded into counters as each batch arrives; only kept records, subdirectories and link
        // occurrences are retained. Children are committed in one call, since another worker appending between two
        // batches would break the arena's contiguous-children rule.
        var prepared = PreparedListing()
        do {
            try forEachBatch(item.components) { batch in
                prepared.absorb(batch, role: role, access: access, rules: rules, dev: info.dev)
            }
        } catch {
            handleFailure(error, item: item)
            return
        }
        if queue.isCancelled { return }
        if prepared.deviceGone {
            fail(.volumeRemoved)
            return
        }

        let first = builder.withLock { builder -> StorageNodeID in
            let range = builder.appendChildren(of: item.node, prepared.records)
            builder.setDirFacts(item.node, markers: prepared.markers, flags: [])
            if prepared.smallCount > 0 || prepared.smallBytes > 0 {
                builder.addSmall(item.node, bytes: prepared.smallBytes, count: prepared.smallCount,
                                 maxMtime: prepared.maxMtime)
            }
            for link in prepared.links {
                let occurrence = link.recordIndex.map { range.lowerBound + Int32($0) } ?? item.node
                builder.addLink(link.identity, linkCount: link.linkCount, bytes: link.bytes,
                                occurrence: occurrence, privateBytes: link.privateBytes)
            }
            return range.lowerBound
        }
        files.add(prepared.files, ordering: .relaxed)
        bytes.add(prepared.bytes, ordering: .relaxed)
        queue.push(prepared.subdirs.map { sub in
            WalkItem(node: first + Int32(sub.recordIndex),
                     components: item.components + [String(decoding: sub.name, as: UTF8.self)],
                     kind: sub.isPackage ? .package : .directory)
        })
    }

    /// Sizes a package's whole subtree into the package node: no children, no markers, nothing kept. If any part
    /// cannot be read the package is marked restricted (size unknown) rather than shown smaller than it is.
    private func walkPackage(_ item: WalkItem) {
        var total: UInt64 = 0
        var count: UInt32 = 0
        var maxMtime: Int64 = 0
        var links: [PendingLink] = []
        var seen = 0
        var incomplete = false
        var deviceGone = false
        var pending = [item.components]
        while let components = pending.popLast(), !queue.isCancelled {
            do {
                try forEachBatch(components) { entries in
                    seen += entries.count
                    for entry in entries {
                        if entry.errorCode != 0 {
                            if VolumeWatch.isVolumeGone(errno: entry.errorCode) { deviceGone = true } else { incomplete = true }
                            continue
                        }
                        switch entry.kind {
                        case .directory:
                            let skipped = entry.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
                                || entry.fileFlags & UInt32(SF_DATALESS) != 0
                            if skipped {
                                incomplete = true
                            } else {
                                pending.append(components + [String(decoding: entry.name, as: UTF8.self)])
                            }
                        case .regular, .symlink, .other:
                            count += 1
                            maxMtime = max(maxMtime, entry.mtime)
                            if entry.kind == .regular, entry.linkCount > 1 {
                                // The package node holds the occurrence, but the link's own depth is below it.
                                links.append(PendingLink(entry, dev: info.dev, recordIndex: nil,
                                                         depth: Int32(components.count + 1)))
                            } else {
                                total += entry.allocBytes
                            }
                        }
                    }
                }
            } catch {
                if components == item.components {
                    handleFailure(error, item: item)
                    return
                }
                if VolumeWatch.isVolumeGone(errno: error.errno) {
                    fail(.volumeRemoved)
                    return
                }
                if error.errno != ENOENT { incomplete = true }
                DiskTools.log.info("package walk skipped \(components.joined(separator: "/")): \(error.op) errno \(error.errno)")
            }
        }
        if queue.isCancelled { return }
        if deviceGone {
            fail(.volumeRemoved)
            return
        }
        files.add(seen, ordering: .relaxed)
        bytes.add(total, ordering: .relaxed)
        builder.withLock { builder in
            if incomplete {
                builder.setRestricted(item.node)
                return
            }
            builder.addSmall(item.node, bytes: total, count: count, maxMtime: maxMtime)
            for link in links {
                builder.addLink(link.identity, linkCount: link.linkCount, bytes: link.bytes, occurrence: item.node,
                                privateBytes: link.privateBytes, depth: link.depth)
            }
        }
    }

    private func handleFailure(_ error: ListError, item: WalkItem) {
        let path = ([root.path] + item.components).joined(separator: "/")
        if VolumeWatch.isVolumeGone(errno: error.errno) {
            fail(.volumeRemoved)
        } else if item.node == 0 {
            fail(.rootUnreadable(path))
        } else if error.errno == ENOENT {
            // Deleted between the parent's listing and ours: nothing to show.
            return
        } else {
            if error.errno != EACCES, error.errno != EPERM {
                DiskTools.log.error("listing \(path) failed: \(error.op) errno \(error.errno)")
            }
            builder.withLock { $0.setRestricted(item.node) }
        }
    }

    // MARK: - Classification

    struct PendingLink: Sendable {
        var identity: FileIdentity
        var linkCount: UInt16
        var bytes: UInt64
        /// Index into the listing's records for a kept file; nil = folded into the directory.
        var recordIndex: Int?
        var privateBytes: UInt64?
        var depth: Int32?

        init(_ entry: ListedEntry, dev: Int32, recordIndex: Int?, depth: Int32? = nil) {
            identity = FileIdentity(dev: dev, ino: entry.fileID, isDirectory: false)
            linkCount = UInt16(clamping: entry.linkCount)
            bytes = entry.allocBytes
            self.recordIndex = recordIndex
            privateBytes = entry.privateBytes
            self.depth = depth
        }
    }

    struct Subdir: Sendable {
        var recordIndex: Int
        var name: [UInt8]
        var isPackage: Bool
    }

    /// Everything one directory's listing contributes, built batch by batch.
    struct PreparedListing: Sendable {
        var records: [NodeRecord] = []
        var subdirs: [Subdir] = []
        var links: [PendingLink] = []
        var smallBytes: UInt64 = 0
        var smallCount: UInt32 = 0
        var maxMtime: Int64 = 0
        var markers: StorageMarker = []
        var files = 0
        var bytes: UInt64 = 0
        /// An entry reported the device gone (`ENXIO`/`EIO`/`ENODEV`): the volume is failing, not just one file.
        var deviceGone = false

        /// Spec §5.2 / §5.3 keep and fold rules for one batch of entries.
        mutating func absorb(_ entries: [ListedEntry], role: WalkRules.Role, access: ScanAccessPolicy,
                             rules: WalkRules, dev: Int32) {
            records.reserveCapacity(records.count + entries.count)
            for entry in entries {
                files += 1
                if entry.errorCode != 0 {
                    if VolumeWatch.isVolumeGone(errno: entry.errorCode) { deviceGone = true }
                    // The kernel could not read this entry; show it as unreadable rather than lose its place.
                    records.append(NodeRecord(name: entry.name, flags: [.directory, .restricted], allocBytes: 0,
                                              fileID: 0, mtime: 0, addedTime: 0))
                    continue
                }
                if let marker = rules.markers.marker(for: entry.name) { markers.formUnion(marker) }
                var flags: StorageNodeFlags = []
                if WalkRules.isHidden(entry.name, fileFlags: entry.fileFlags) { flags.insert(.hidden) }
                let dataless = entry.fileFlags & UInt32(SF_DATALESS) != 0
                if dataless { flags.insert(.dataless) }

                switch entry.kind {
                case .directory:
                    flags.insert(.directory)
                    var enter = !dataless
                    if entry.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
                        || WalkRules.skippedSystemDirs.contains(entry.name) {
                        flags.insert(.skippedMount)
                        enter = false
                    }
                    if role.holdsAppContainers, !access.fullDiskAccess, !access.isOwnContainer(entry.name) {
                        // Opening it would raise a consent prompt and block this worker until answered.
                        flags.insert(.restricted)
                        enter = false
                    }
                    if WalkRules.isBuildDir(entry.name) { flags.insert(.buildDir) }
                    let package = enter && WalkRules.isPackage(entry.name)
                    if package { flags.insert(.package) }
                    if enter {
                        subdirs.append(Subdir(recordIndex: records.count, name: entry.name, isPackage: package))
                    }
                    records.append(NodeRecord(name: entry.name, flags: flags, allocBytes: 0, fileID: entry.fileID,
                                              mtime: entry.mtime, addedTime: entry.addedTime))
                case .regular:
                    let isLink = entry.linkCount > 1
                    bytes += entry.allocBytes
                    if role.keepAllChildren || entry.allocBytes >= WalkRules.keptFileThreshold {
                        if isLink { links.append(PendingLink(entry, dev: dev, recordIndex: records.count)) }
                        records.append(NodeRecord(name: entry.name, flags: flags,
                                                  allocBytes: isLink ? 0 : entry.allocBytes, fileID: entry.fileID,
                                                  mtime: entry.mtime, addedTime: entry.addedTime))
                    } else {
                        fold(entry, bytes: isLink ? 0 : entry.allocBytes)
                        if isLink { links.append(PendingLink(entry, dev: dev, recordIndex: nil)) }
                    }
                case .symlink where role.keepAllChildren:
                    flags.insert(.symlink)
                    records.append(NodeRecord(name: entry.name, flags: flags, allocBytes: entry.allocBytes,
                                              fileID: entry.fileID, mtime: entry.mtime, addedTime: entry.addedTime))
                case .symlink, .other:
                    fold(entry, bytes: entry.allocBytes)
                }
            }
        }

        private mutating func fold(_ entry: ListedEntry, bytes folded: UInt64) {
            smallBytes += folded
            smallCount += 1
            maxMtime = max(maxMtime, entry.mtime)
        }
    }

    // MARK: - Events

    private func publish(_ event: ScanEvent) {
        closed.withLock { closed in
            if !closed { continuation.yield(event) }
        }
    }

    private var isClosed: Bool { closed.withLock { $0 } }

    private func startTicker() {
        let ticker = Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            var nextPartial = clock.now + .milliseconds(300)
            while !isClosed {
                do {
                    try await Task.sleep(for: progressInterval)
                } catch {
                    return
                }
                publish(.progress(progress()))
                // ~3 Hz, but a snapshot sorts every node, so it backs off to keep its share of the scan's
                // wall time near a fifth on huge trees.
                if clock.now >= nextPartial, !isClosed {
                    let started = clock.now
                    // Copy the arrays' references under the lock, sort outside it: workers only wait for the
                    // reference copy (they pay one copy-on-write per array afterwards).
                    let frozen = builder.withLock { $0 }
                    publish(.partial(frozen.snapshot()))
                    nextPartial = clock.now + max(.milliseconds(300), (clock.now - started) * 4)
                }
            }
        }
        onFinish { ticker.cancel() }
    }

    private func progress() -> ScanProgress {
        let path = ([root.path] + currentComponents.withLock { $0 }).joined(separator: "/")
        return ScanProgress(files: files.load(ordering: .relaxed), bytes: bytes.load(ordering: .relaxed),
                            currentPath: path)
    }

    /// Exactly one terminal event, from the last worker to leave, so no listing is still open when it is sent.
    /// The root descriptor is released first: a consumer that sees the terminal event may eject the volume.
    private func sendTerminal() {
        let terminal: ScanEvent
        if let reason = failure.withLock({ $0 }) {
            terminal = .failed(reason)
        } else {
            terminal = .finished(builder.withLock { $0 }.finalize(scanDate: Date(), lastEventId: lastEventId))
        }
        lister.release()
        let first = closed.withLock { closed -> Bool in
            guard !closed else { return false }
            closed = true
            continuation.yield(terminal)
            return true
        }
        guard first else { return }
        for cleanup in helpers.withLock({ $0 }) { cleanup() }
        continuation.finish()
    }
}
