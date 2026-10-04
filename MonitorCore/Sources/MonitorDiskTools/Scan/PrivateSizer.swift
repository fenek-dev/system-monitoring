import Foundation
import MonitorModel

/// Private-size pass: what deleting each cleanup item would actually free (`ATTR_CMNEXT_PRIVATESIZE`, spikes §3),
/// instead of the scan's allocated bytes, which also count extents shared with clones and snapshots.
///
/// Runs on the caller's queue (the engine's serial `.utility` queue); the lister must request private sizes
/// (`BulkLister(root:, includePrivateSize: true)`).
public struct PrivateSizer: Sendable {
    public struct Output: Sendable {
        public var items: [CleanupItem]
        /// Index into `StorageTree.linkGroups` → private size of that hard-linked file.
        public var linkGroupSizes: [Int32: LinkGroupSize]
    }

    private let lister: any DirectoryLister
    private let rootPath: String

    public init(lister: any DirectoryLister, rootPath: String) {
        self.lister = lister
        self.rootPath = rootPath
    }

    /// Items not reached because `isCancelled` turned true come back unchanged.
    public func run(items: [CleanupItem], tree: StorageTree,
                    isCancelled: @Sendable () -> Bool = { false }) -> Output {
        // The caller's thread is borrowed (a shared queue): placeholders must not be downloaded by anything this
        // pass touches, and the thread's previous policy comes back afterwards.
        DatalessPolicy.withMaterializationOff { runPass(items: items, tree: tree, isCancelled: isCancelled) }
    }

    private func runPass(items: [CleanupItem], tree: StorageTree, isCancelled: @Sendable () -> Bool) -> Output {
        do {
            _ = try lister.rootInfo()
        } catch {
            DiskTools.log.error("private size pass: root \(rootPath) unavailable: \(error.op) errno \(error.errno)")
            var unmeasured = items
            for index in unmeasured.indices {
                unmeasured[index].privateBytesExcludingLinks = nil
                unmeasured[index].sizeProvenance = .estimate
            }
            return Output(items: unmeasured, linkGroupSizes: [:])
        }
        defer { lister.release() }
        var groupByIdentity: [FileIdentity: Int32] = [:]
        for (index, group) in tree.linkGroups.enumerated() { groupByIdentity[group.identity] = Int32(index) }
        var output = Output(items: items, linkGroupSizes: [:])
        for index in items.indices {
            if isCancelled() { break }
            var walk = Walk(dev: tree.dev, groupByIdentity: groupByIdentity)
            measure(items[index], into: &walk, isCancelled: isCancelled)
            if isCancelled() { break }
            if walk.unreadable {
                // Part of the item could not be read: its allocated size stays the answer.
                output.items[index].privateBytesExcludingLinks = nil
                output.items[index].sizeProvenance = .estimate
            } else {
                output.items[index].privateBytesExcludingLinks = walk.bytes
                output.items[index].sizeProvenance = walk.exact ? .exact : .estimate
            }
            for (group, size) in walk.linkSizes where output.linkGroupSizes[group] == nil {
                output.linkGroupSizes[group] = size
            }
        }
        return output
    }

    private struct Walk {
        var dev: Int32
        var groupByIdentity: [FileIdentity: Int32]
        var bytes: UInt64 = 0
        /// Every counted file reported a private size that is its whole allocation. A file sharing extents (a clone,
        /// a snapshot) reports less, and clones inside the same item share those extents with each other, so the
        /// sum is then only a lower bound.
        var exact = true
        var unreadable = false
        var linkSizes: [Int32: LinkGroupSize] = [:]

        mutating func add(_ entry: ListedEntry) {
            if entry.linkCount > 1 {
                guard let group = groupByIdentity[FileIdentity(dev: dev, ino: entry.fileID, isDirectory: false)] else {
                    // A multi-link inode the scan never grouped: its other links are unknown, so what deleting this
                    // one frees is unknown too. Count its allocation as an estimate.
                    bytes += entry.allocBytes
                    exact = false
                    return
                }
                // Counted through the group (all its links must be inside the deleted set to free it). Less private
                // than allocated means shared extents, so the figure is only a lower bound.
                if linkSizes[group] == nil {
                    let isExact = entry.privateBytes.map { $0 >= entry.allocBytes } ?? false
                    linkSizes[group] = LinkGroupSize(privateBytes: entry.privateBytes,
                                                     provenance: isExact ? .exact : .estimate)
                }
                return
            }
            guard let privateBytes = entry.privateBytes else {
                bytes += entry.allocBytes
                exact = false
                return
            }
            bytes += privateBytes
            if privateBytes < entry.allocBytes { exact = false }
        }
    }

    private func measure(_ item: CleanupItem, into walk: inout Walk, isCancelled: @Sendable () -> Bool) {
        let rel: RelativePath
        let top: ListedEntry
        do {
            rel = try RelativePath.confined(item.path, under: rootPath)
            top = try lister.attributes(of: rel)
        } catch {
            DiskTools.log.info("private size: \(item.path) unreadable: \(String(describing: error))")
            walk.unreadable = true
            return
        }
        switch top.kind {
        case .regular: walk.add(top)
        case .directory:
            // Flags came from `attributes` without opening anything; a placeholder directory is never entered.
            if top.fileFlags & UInt32(SF_DATALESS) != 0 {
                walk.unreadable = true
            } else {
                walkDirectory(rel, into: &walk, isCancelled: isCancelled)
            }
        case .symlink, .other: break
        }
    }

    private func walkDirectory(_ start: RelativePath, into walk: inout Walk, isCancelled: @Sendable () -> Bool) {
        var pending = [start]
        while let rel = pending.popLast(), !isCancelled() {
            do {
                let handle = try lister.open(rel)
                while !isCancelled() {
                    let batch = try lister.list(handle)
                    for entry in batch.entries {
                        if entry.errorCode != 0 {
                            walk.unreadable = true
                            continue
                        }
                        switch entry.kind {
                        case .regular: walk.add(entry)
                        case .directory:
                            let skipped = entry.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
                                || entry.fileFlags & UInt32(SF_DATALESS) != 0
                            guard !skipped else { continue }
                            do {
                                let name = String(decoding: entry.name, as: UTF8.self)
                                pending.append(try RelativePath(components: rel.components + [name]))
                            } catch {
                                walk.unreadable = true
                            }
                        case .symlink, .other: break
                        }
                    }
                    if batch.done || batch.entries.isEmpty { break }
                }
            } catch {
                DiskTools.log.info("private size: \(rel) unreadable: \(error.op) errno \(error.errno)")
                walk.unreadable = true
            }
        }
    }
}
