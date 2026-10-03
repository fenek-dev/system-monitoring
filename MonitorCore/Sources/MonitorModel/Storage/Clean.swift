import Foundation

public enum DenyReason: Equatable, Codable, Sendable {
    /// Target is or contains an anchor (`/`, `~`, `~/Library` and its children, system dirs, the scan root).
    case anchor
    /// Target is, contains or is inside a protected subtree (Keychains, Mail, iCloud, our own data, …).
    case protected
    case outsideRoot
    /// Permanent delete is only allowed inside the home folder.
    case removeOutsideHome
    /// The identity chain could not be established (unreadable ancestor, stale policy).
    case unverifiable
}

public enum SkipReason: Equatable, Codable, Sendable {
    case denied(DenyReason)
    case inUse
    case changedSinceScan
    case notPermitted
    case noTrash
    case stagingOtherVolume
    case vanished
    /// Rolling an item back out of staging found its original name taken; it stays in `staging/pending`.
    case rollbackCollision
    case cancelled
    case failed(String)
}

public struct CleanItemOutcome: Equatable, Sendable {
    public var itemID: Int32
    public var detachedBytes: UInt64
    /// Tree nodes that are gone (the item's node, or committed children for keep-parent items).
    public var removedNodes: [StorageNodeID]
    public var committedChildren: Int
    public var skippedChildren: Int
    /// Some but not all of the item went (keep-parent with skipped children, or a delete that left files).
    public var partial: Bool
    public var skip: SkipReason?
    public var trashedTo: String?

    public init(itemID: Int32, detachedBytes: UInt64 = 0, removedNodes: [StorageNodeID] = [],
                committedChildren: Int = 0, skippedChildren: Int = 0, partial: Bool = false, skip: SkipReason? = nil,
                trashedTo: String? = nil) {
        self.itemID = itemID
        self.detachedBytes = detachedBytes
        self.removedNodes = removedNodes
        self.committedChildren = committedChildren
        self.skippedChildren = skippedChildren
        self.partial = partial
        self.skip = skip
        self.trashedTo = trashedTo
    }
}

public enum CleanEvent: Sendable {
    case item(CleanItemOutcome)
    case freed(UInt64)
    case restored(itemID: Int32, finalPath: String)
    /// Exactly once, after detaching stopped and deletions drained; the stream then finishes.
    case finished(CleanReport)
}

public struct CleanReport: Equatable, Sendable {
    public var freedBytes: UInt64
    public var trashedBytes: UInt64
    public var evictedBytes: UInt64
    public var outcomes: [CleanItemOutcome]
    public var cancelled: Bool
    /// Items left in `staging/pending` (rollback collisions); reported, never deleted.
    public var stagingLeftovers: Int
    /// Trash entries of this clean; nil when nothing was trashed.
    public var undo: UndoRecord?

    public init(freedBytes: UInt64 = 0, trashedBytes: UInt64 = 0, evictedBytes: UInt64 = 0,
                outcomes: [CleanItemOutcome] = [], cancelled: Bool = false, stagingLeftovers: Int = 0,
                undo: UndoRecord? = nil) {
        self.freedBytes = freedBytes
        self.trashedBytes = trashedBytes
        self.evictedBytes = evictedBytes
        self.outcomes = outcomes
        self.cancelled = cancelled
        self.stagingLeftovers = stagingLeftovers
        self.undo = undo
    }
}

public struct UndoRecord: Equatable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var entries: [UndoEntry]

    public init(id: UUID = UUID(), date: Date, entries: [UndoEntry]) {
        self.id = id
        self.date = date
        self.entries = entries
    }
}

public struct UndoEntry: Equatable, Codable, Sendable {
    public var itemID: Int32
    public var nodeID: StorageNodeID?
    public var originalPath: String
    public var trashPath: String
    public var identity: FileIdentity
    /// Actual Trash dir from `trashItem`'s resulting URL (`~/.Trash` or a volume's `.Trashes/<uid>`).
    public var trashParentPath: String
    public var trashParentIdentity: FileIdentity

    public init(itemID: Int32, nodeID: StorageNodeID?, originalPath: String, trashPath: String,
                identity: FileIdentity, trashParentPath: String, trashParentIdentity: FileIdentity) {
        self.itemID = itemID
        self.nodeID = nodeID
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.identity = identity
        self.trashParentPath = trashParentPath
        self.trashParentIdentity = trashParentIdentity
    }
}

/// What survives a closed window: enough for the sidebar value and popover link.
public struct StorageSummary: Equatable, Codable, Sendable {
    public var root: ScanRoot
    public var scanDate: Date
    public var reclaimableBytes: UInt64?
    public var provenance: SizeProvenance
    public var trashBytes: UInt64?

    public init(root: ScanRoot, scanDate: Date, reclaimableBytes: UInt64?, provenance: SizeProvenance,
                trashBytes: UInt64?) {
        self.root = root
        self.scanDate = scanDate
        self.reclaimableBytes = reclaimableBytes
        self.provenance = provenance
        self.trashBytes = trashBytes
    }
}
