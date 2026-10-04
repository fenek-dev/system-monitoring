import Foundation

public enum CleanupCategory: String, CaseIterable, Codable, Sendable {
    case userCaches, leftovers, largeOld, developer, trash
}

public enum SafetyTier: String, Codable, Sendable {
    case safe, review
}

public enum DeleteMode: String, Codable, Sendable {
    /// Permanent delete through the staging journal (regenerable data).
    case remove
    case trash
    /// `evictUbiquitousItem`: drop the local copy of an iCloud file.
    case evict
    /// `xcrun simctl delete unavailable`.
    case simctl
    /// Info only (Docker), never deleted.
    case none
}

/// Ordered best to worst, so `max()` gives the worst of a selection.
public enum SizeProvenance: String, Codable, Comparable, Sendable {
    /// Private bytes (`ATTR_CMNEXT_PRIVATESIZE`).
    case exact
    /// Allocated bytes; or private bytes of a clone set, which is only a lower bound.
    case estimate
    case unavailable

    private var rank: Int {
        switch self {
        case .exact: 0
        case .estimate: 1
        case .unavailable: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct OwnerApp: Hashable, Codable, Sendable {
    public var bundleID: String
    public var name: String
    public var appPath: String?

    public init(bundleID: String, name: String, appPath: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.appPath = appPath
    }
}

public struct CleanupItem: Identifiable, Equatable, Sendable {
    public var id: Int32
    /// Group row this item sits under (per owning app), nil for top-level rows.
    public var parentID: Int32?
    public var nodeID: StorageNodeID?
    public var path: String
    public var name: String
    public var category: CleanupCategory
    public var tier: SafetyTier
    public var mode: DeleteMode
    /// Identity at scan time; the cleaner refuses the item if the live identity differs.
    public var identity: FileIdentity?
    public var allocBytes: UInt64
    /// Private bytes of the item's non-hard-linked files; nil until the private-size pass ran. Hard-linked files
    /// are counted through `linkGroupIndices` (`ReclaimAccumulator`).
    public var privateBytesExcludingLinks: UInt64?
    /// Indices into `StorageTree.linkGroups` with at least one occurrence inside this item.
    public var linkGroupIndices: [Int32]
    public var sizeProvenance: SizeProvenance
    public var lastUsed: Date?
    public var owner: OwnerApp?
    public var runningApp: Bool
    /// Cache dir: children are deleted, the dir itself stays.
    public var keepParent: Bool
    public var ignored: Bool
    public var note: String?

    public init(
        id: Int32, parentID: Int32? = nil, nodeID: StorageNodeID?, path: String, name: String,
        category: CleanupCategory, tier: SafetyTier, mode: DeleteMode, identity: FileIdentity?, allocBytes: UInt64,
        privateBytesExcludingLinks: UInt64? = nil, linkGroupIndices: [Int32] = [],
        sizeProvenance: SizeProvenance = .estimate, lastUsed: Date? = nil, owner: OwnerApp? = nil,
        runningApp: Bool = false, keepParent: Bool = false, ignored: Bool = false, note: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.nodeID = nodeID
        self.path = path
        self.name = name
        self.category = category
        self.tier = tier
        self.mode = mode
        self.identity = identity
        self.allocBytes = allocBytes
        self.privateBytesExcludingLinks = privateBytesExcludingLinks
        self.linkGroupIndices = linkGroupIndices
        self.sizeProvenance = sizeProvenance
        self.lastUsed = lastUsed
        self.owner = owner
        self.runningApp = runningApp
        self.keepParent = keepParent
        self.ignored = ignored
        self.note = note
    }
}

/// Private size of a hard-linked file, from the private-size pass.
public struct LinkGroupSize: Equatable, Sendable {
    public var privateBytes: UInt64?
    /// `.exact` only when `privateBytes` came from `ATTR_CMNEXT_PRIVATESIZE`.
    public var provenance: SizeProvenance

    public init(privateBytes: UInt64?, provenance: SizeProvenance) {
        self.privateBytes = privateBytes
        self.provenance = provenance
    }
}

public struct CleanupSet: Equatable, Sendable {
    public var treeVersion: UInt64
    public var items: [CleanupItem]
    public var ownershipResolved: Bool
    public var privateSizesFinal: Bool
    /// nil when `~/.Trash` is unreadable.
    public var trashBytes: UInt64?
    /// Keyed by index into `StorageTree.linkGroups`; overrides the group's scan-time size in `ReclaimAccumulator`.
    public var linkGroupSizes: [Int32: LinkGroupSize]

    public init(treeVersion: UInt64, items: [CleanupItem], ownershipResolved: Bool, privateSizesFinal: Bool,
                trashBytes: UInt64?, linkGroupSizes: [Int32: LinkGroupSize] = [:]) {
        self.treeVersion = treeVersion
        self.items = items
        self.ownershipResolved = ownershipResolved
        self.privateSizesFinal = privateSizesFinal
        self.trashBytes = trashBytes
        self.linkGroupSizes = linkGroupSizes
    }
}

public struct ClassifyOptions: Equatable, Sendable {
    public var now: Date
    /// Large & Old: at least this size regardless of age (spec default 500 MB).
    public var largeBytes: UInt64
    /// Large & Old: at least this size and unused for `oldAge` (spec default 50 MB, 6 months).
    public var oldBytes: UInt64
    public var oldAge: TimeInterval
    public var ignoredPaths: Set<String>

    public static let defaultLargeBytes: UInt64 = 500_000_000
    public static let defaultOldBytes: UInt64 = 50_000_000
    /// Six months as 183 days.
    public static let defaultOldAge: TimeInterval = 183 * 86400

    public init(now: Date, largeBytes: UInt64 = Self.defaultLargeBytes, oldBytes: UInt64 = Self.defaultOldBytes,
                oldAge: TimeInterval = Self.defaultOldAge, ignoredPaths: Set<String> = []) {
        self.now = now
        self.largeBytes = largeBytes
        self.oldBytes = oldBytes
        self.oldAge = oldAge
        self.ignoredPaths = ignoredPaths
    }
}
