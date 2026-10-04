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
    private let queue: WorkQueue<WalkItem>
    private let builder: Mutex<StorageTreeBuilder>
    private let continuation: AsyncStream<ScanEvent>.Continuation
    private let threadCount: Int

    private let failure = Mutex<ScanFailure?>(nil)
    private let aliveWorkers: Atomic<Int>
    private let terminalSent = Atomic<Bool>(false)
    private let files = Atomic<Int>(0)
    private let bytes = Atomic<UInt64>(0)
    private let currentComponents = Mutex<[String]>([])
    private let helpers = Mutex<[@Sendable () -> Void]>([])

    init(root: ScanRoot, info: ScanRootInfo, lastEventId: UInt64, lister: any DirectoryLister, rules: WalkRules,
         threads: Int, continuation: AsyncStream<ScanEvent>.Continuation) {
        self.root = root
        self.info = info
        self.lastEventId = lastEventId
        self.lister = lister
        self.rules = rules
        self.threadCount = threads
        self.queue = WorkQueue(workers: threads)
        self.builder = Mutex(StorageTreeBuilder(root: root, dev: info.dev, volumeUUID: info.volumeUUID,
                                                rootFileID: info.fileID, rootMtime: info.mtime))
        self.continuation = continuation
        self.aliveWorkers = Atomic(threads)
    }

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
        // Workers must never materialize iCloud placeholders by touching them (spikes §8).
        if setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                          IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0 {
            DiskTools.log.error("setiopolicy_np(materialize dataless) failed, errno \(Darwin.errno)")
        }
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

    /// Every batch of one directory. Collected locally and committed once: another worker appending between two
    /// batches would break the arena's contiguous-children rule.
    private func listAll(_ components: [String]) throws(ListError) -> [ListedEntry] {
        let handle = try lister.open(try relative(components))
        var all: [ListedEntry] = []
        while !queue.isCancelled {
            let batch = try lister.list(handle)
            all.append(contentsOf: batch.entries)
            if batch.done || batch.entries.isEmpty { break }
        }
        return all
    }

    private func walkDirectory(_ item: WalkItem) {
        let entries: [ListedEntry]
        do {
            entries = try listAll(item.components)
        } catch {
            handleFailure(error, item: item)
            return
        }
        if queue.isCancelled { return }

        let keepAll = rules.keepAllChildrenOf.contains(item.components)
        let prepared = Self.prepare(entries, keepAll: keepAll, rules: rules, dev: info.dev)
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

    /// Sizes a package's whole subtree into the package node: no children, no markers, nothing kept.
    private func walkPackage(_ item: WalkItem) {
        var total: UInt64 = 0
        var count: UInt32 = 0
        var maxMtime: Int64 = 0
        var links: [PendingLink] = []
        var seen = 0
        var pending = [item.components]
        while let components = pending.popLast(), !queue.isCancelled {
            let entries: [ListedEntry]
            do {
                entries = try listAll(components)
            } catch {
                if components == item.components {
                    handleFailure(error, item: item)
                    return
                }
                if VolumeWatch.isVolumeGone(errno: error.errno) {
                    fail(.volumeRemoved)
                    return
                }
                DiskTools.log.info("package walk skipped \(components.joined(separator: "/")): \(error.op) errno \(error.errno)")
                continue
            }
            seen += entries.count
            for entry in entries where entry.errorCode == 0 {
                switch entry.kind {
                case .directory:
                    let skipped = entry.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
                        || entry.fileFlags & UInt32(SF_DATALESS) != 0
                    if !skipped { pending.append(components + [String(decoding: entry.name, as: UTF8.self)]) }
                case .regular, .symlink, .other:
                    count += 1
                    maxMtime = max(maxMtime, entry.mtime)
                    if entry.kind == .regular, entry.linkCount > 1 {
                        links.append(PendingLink(entry, dev: info.dev, recordIndex: nil))
                    } else {
                        total += entry.allocBytes
                    }
                }
            }
        }
        if queue.isCancelled { return }
        files.add(seen, ordering: .relaxed)
        bytes.add(total, ordering: .relaxed)
        builder.withLock { builder in
            builder.addSmall(item.node, bytes: total, count: count, maxMtime: maxMtime)
            for link in links {
                builder.addLink(link.identity, linkCount: link.linkCount, bytes: link.bytes, occurrence: item.node,
                                privateBytes: link.privateBytes)
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

        init(_ entry: ListedEntry, dev: Int32, recordIndex: Int?) {
            identity = FileIdentity(dev: dev, ino: entry.fileID, isDirectory: false)
            linkCount = UInt16(clamping: entry.linkCount)
            bytes = entry.allocBytes
            self.recordIndex = recordIndex
            privateBytes = entry.privateBytes
        }
    }

    struct Subdir: Sendable {
        var recordIndex: Int
        var name: [UInt8]
        var isPackage: Bool
    }

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
    }

    /// Spec §5.2 / §5.3 keep and fold rules for one directory's entries.
    static func prepare(_ entries: [ListedEntry], keepAll: Bool, rules: WalkRules, dev: Int32) -> PreparedListing {
        var out = PreparedListing()
        out.records.reserveCapacity(entries.count)
        for entry in entries {
            out.files += 1
            if entry.errorCode != 0 {
                // The kernel could not read this entry; show it as unreadable rather than lose its place.
                out.records.append(NodeRecord(name: entry.name, flags: [.directory, .restricted], allocBytes: 0,
                                              fileID: 0, mtime: 0, addedTime: 0))
                continue
            }
            if let marker = rules.markers.marker(for: entry.name) { out.markers.formUnion(marker) }
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
                if WalkRules.isBuildDir(entry.name) { flags.insert(.buildDir) }
                let package = enter && WalkRules.isPackage(entry.name)
                if package { flags.insert(.package) }
                if enter {
                    out.subdirs.append(Subdir(recordIndex: out.records.count, name: entry.name, isPackage: package))
                }
                out.records.append(NodeRecord(name: entry.name, flags: flags, allocBytes: 0, fileID: entry.fileID,
                                              mtime: entry.mtime, addedTime: entry.addedTime))
            case .regular:
                let isLink = entry.linkCount > 1
                out.bytes += entry.allocBytes
                if keepAll || entry.allocBytes >= WalkRules.keptFileThreshold {
                    if isLink { out.links.append(PendingLink(entry, dev: dev, recordIndex: out.records.count)) }
                    out.records.append(NodeRecord(name: entry.name, flags: flags,
                                                  allocBytes: isLink ? 0 : entry.allocBytes, fileID: entry.fileID,
                                                  mtime: entry.mtime, addedTime: entry.addedTime))
                } else {
                    out.fold(entry, bytes: isLink ? 0 : entry.allocBytes)
                    if isLink { out.links.append(PendingLink(entry, dev: dev, recordIndex: nil)) }
                }
            case .symlink where keepAll:
                flags.insert(.symlink)
                out.records.append(NodeRecord(name: entry.name, flags: flags, allocBytes: entry.allocBytes,
                                              fileID: entry.fileID, mtime: entry.mtime, addedTime: entry.addedTime))
            case .symlink, .other:
                out.fold(entry, bytes: entry.allocBytes)
            }
        }
        return out
    }

    // MARK: - Events

    private func startTicker() {
        let ticker = Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            var nextPartial = clock.now + .milliseconds(300)
            while !terminalSent.load(ordering: .acquiring) {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                if terminalSent.load(ordering: .acquiring) { return }
                continuation.yield(.progress(progress()))
                // ~3 Hz, but a snapshot sorts every node, so it backs off to keep its share of the scan's
                // wall time near a fifth on huge trees.
                if clock.now >= nextPartial {
                    let started = clock.now
                    // Copy the arrays' references under the lock, sort outside it: workers only wait for the
                    // reference copy (they pay one copy-on-write per array afterwards).
                    let frozen = builder.withLock { $0 }
                    continuation.yield(.partial(frozen.snapshot()))
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
    private func sendTerminal() {
        guard !terminalSent.exchange(true, ordering: .acquiringAndReleasing) else { return }
        if let reason = failure.withLock({ $0 }) {
            continuation.yield(.failed(reason))
        } else {
            let tree = builder.withLock { $0 }.finalize(scanDate: Date(), lastEventId: lastEventId)
            continuation.yield(.finished(tree))
        }
        for cleanup in helpers.withLock({ $0 }) { cleanup() }
        continuation.finish()
    }
}

extension ScanRun.PreparedListing {
    fileprivate mutating func fold(_ entry: ListedEntry, bytes: UInt64) {
        smallBytes += bytes
        smallCount += 1
        maxMtime = max(maxMtime, entry.mtime)
    }
}
