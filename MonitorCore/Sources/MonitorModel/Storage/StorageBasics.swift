import Foundation

/// Index into a `StorageTree`'s arrays. Node 0 is the scan root.
public typealias StorageNodeID = Int32

public struct StorageNodeFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = StorageNodeFlags(rawValue: 1 << 0)
    /// Bundle dir (`.app`, `.photoslibrary`, …): walked for size, presented as a leaf.
    public static let package = StorageNodeFlags(rawValue: 1 << 1)
    /// Unreadable dir: size unknown (`size == nil`), contributes 0 to its ancestors.
    public static let restricted = StorageNodeFlags(rawValue: 1 << 2)
    /// `SF_DATALESS` (iCloud placeholder): never entered.
    public static let dataless = StorageNodeFlags(rawValue: 1 << 3)
    /// Mount point or autofs trigger: never entered.
    public static let skippedMount = StorageNodeFlags(rawValue: 1 << 4)
    public static let hidden = StorageNodeFlags(rawValue: 1 << 5)
    /// Sealed system volume shown as one opaque node.
    public static let sealed = StorageNodeFlags(rawValue: 1 << 6)
    public static let symlink = StorageNodeFlags(rawValue: 1 << 7)
    /// Build output dir (`node_modules`, `.build`, `target`, …): its `subtreeMaxMtime` does not propagate to the
    /// parent, so a fresh `npm install` doesn't make a stale project look recently used.
    public static let buildDir = StorageNodeFlags(rawValue: 1 << 8)
}

/// Marker files seen in a directory's own listing (raw name compare, no extra syscalls). Set by the scanner,
/// read by the classifier.
public struct StorageMarker: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let git = StorageMarker(rawValue: 1 << 0)                    // .git
    public static let packageJSON = StorageMarker(rawValue: 1 << 1)            // package.json
    public static let packageSwift = StorageMarker(rawValue: 1 << 2)           // Package.swift
    public static let cargoToml = StorageMarker(rawValue: 1 << 3)              // Cargo.toml
    public static let podfile = StorageMarker(rawValue: 1 << 4)                // Podfile
    public static let gradle = StorageMarker(rawValue: 1 << 5)                 // build.gradle(.kts), settings.gradle
    public static let cmakeLists = StorageMarker(rawValue: 1 << 6)             // CMakeLists.txt
    public static let cachedirTag = StorageMarker(rawValue: 1 << 7)            // CACHEDIR.TAG
    public static let cmakeCache = StorageMarker(rawValue: 1 << 8)             // CMakeCache.txt
    public static let swiftpmWorkspaceState = StorageMarker(rawValue: 1 << 9)  // workspace-state.json
    public static let npmLock = StorageMarker(rawValue: 1 << 10)               // .package-lock.json
    public static let pnpmModules = StorageMarker(rawValue: 1 << 11)           // .modules.yaml
    public static let yarnState = StorageMarker(rawValue: 1 << 12)             // .yarn-state.yml
    public static let podsManifest = StorageMarker(rawValue: 1 << 13)          // Manifest.lock
}

/// What a path pointed at when it was observed: identity checks compare all three fields.
public struct FileIdentity: Hashable, Codable, Sendable {
    public var dev: Int32
    public var ino: UInt64
    public var isDirectory: Bool

    public init(dev: Int32, ino: UInt64, isDirectory: Bool) {
        self.dev = dev
        self.ino = ino
        self.isDirectory = isDirectory
    }
}

/// One listed entry handed to `StorageTreeBuilder.appendChildren`.
///
/// Hard-linked files (link count > 1) carry `allocBytes == 0` (and are left out of `addSmall` bytes); their bytes go
/// through `addLink` and `finalize` credits them once, at the lowest-depth occurrence.
public struct NodeRecord: Sendable, Equatable {
    public var name: [UInt8]
    public var flags: StorageNodeFlags
    /// Allocated bytes of a file; 0 for directories (rolled up by `finalize`).
    public var allocBytes: UInt64
    public var fileID: UInt64
    /// Seconds since 1970.
    public var mtime: Int64
    /// `ATTR_CMN_ADDEDTIME`, seconds since 1970 (0 if unknown).
    public var addedTime: Int64

    public init(name: [UInt8], flags: StorageNodeFlags, allocBytes: UInt64, fileID: UInt64, mtime: Int64,
                addedTime: Int64) {
        self.name = name
        self.flags = flags
        self.allocBytes = allocBytes
        self.fileID = fileID
        self.mtime = mtime
        self.addedTime = addedTime
    }

    public init(name: String, flags: StorageNodeFlags, allocBytes: UInt64, fileID: UInt64, mtime: Int64,
                addedTime: Int64) {
        self.init(name: Array(name.utf8), flags: flags, allocBytes: allocBytes, fileID: fileID, mtime: mtime,
                  addedTime: addedTime)
    }
}

/// One per (dev, ino) with link count > 1 seen during the scan (kept files and folded small files alike).
public struct HardLinkGroup: Sendable, Equatable {
    public var identity: FileIdentity
    public var linkCount: UInt16
    public var bytes: UInt64
    /// File node if kept, else the containing dir node; one entry per observed link.
    public var occurrences: [StorageNodeID]

    public init(identity: FileIdentity, linkCount: UInt16, bytes: UInt64, occurrences: [StorageNodeID]) {
        self.identity = identity
        self.linkCount = linkCount
        self.bytes = bytes
        self.occurrences = occurrences
    }
}
