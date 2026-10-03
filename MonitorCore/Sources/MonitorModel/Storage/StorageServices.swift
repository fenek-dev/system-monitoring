import Foundation

/// AppKit facts the storage engine needs, injected as closures so `MonitorDiskTools` / `MonitorRuntime` never import
/// AppKit. Built by `StorageActionsLive` (MonitorScreens).
public struct StoragePlatform: Sendable {
    /// Bundle IDs of running apps (`NSWorkspace.runningApplications`).
    public var runningBundleIDs: @Sendable () async -> Set<String>
    /// `NSWorkspace.urlsForApplications(withBundleIdentifier:)` paths.
    public var appPaths: @Sendable (_ bundleID: String) async -> [String]
    /// Paths of volumes about to unmount (`NSWorkspace.willUnmountNotification`).
    public var willUnmount: @Sendable () -> AsyncStream<String>

    public init(
        runningBundleIDs: @escaping @Sendable () async -> Set<String> = { [] },
        appPaths: @escaping @Sendable (_ bundleID: String) async -> [String] = { _ in [] },
        willUnmount: @escaping @Sendable () -> AsyncStream<String> = { AsyncStream { $0.finish() } }
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.appPaths = appPaths
        self.willUnmount = willUnmount
    }

    public static let none = StoragePlatform()
}

/// Storage page actions, environment-injected (same shape as `ProcessActions`): live = `StorageEngine` composed in
/// `MonitorRuntime`, mock = `MockDataProvider.storageActions(log:)`.
public struct StorageActions: Sendable {
    public var scan: @MainActor @Sendable (ScanRoot, ClassifyOptions) -> AsyncStream<ScanEvent>
    public var cancelScan: @MainActor @Sendable () -> Void
    /// Cached tree + overlay + classification for the root, nil if there is no valid cache.
    public var loadCached: @MainActor @Sendable (ScanRoot, ClassifyOptions) async
        -> (StorageTree, StorageTreeOverlay, CleanupSet)?
    /// Home-root summary only (sidebar, popover); no tree is loaded.
    public var loadSummary: @MainActor @Sendable () async -> StorageSummary?
    public var reclassify: @MainActor @Sendable (ClassifyOptions) async -> CleanupSet?
    /// Deny reasons for Space Map menus.
    public var policy: @MainActor @Sendable () -> StoragePolicy
    /// Ids of items a process currently holds open (or runs from).
    public var checkInUse: @MainActor @Sendable ([CleanupItem]) async -> Set<Int32>
    public var clean: @MainActor @Sendable ([CleanupItem]) -> AsyncStream<CleanEvent>
    public var cancelClean: @MainActor @Sendable () -> Void
    public var undo: @MainActor @Sendable (UndoRecord) -> AsyncStream<CleanEvent>
    public var emptyTrash: @MainActor @Sendable () -> AsyncStream<CleanEvent>
    /// Window closed: drop engine state (tree, overlay, installed apps, Spotlight map).
    public var release: @MainActor @Sendable () -> Void
    public var availableRoots: @MainActor @Sendable () -> [ScanRoot]
    public var hasFullDiskAccess: @MainActor @Sendable () async -> Bool
    public var ignore: @MainActor @Sendable (String) -> Void
    public var unignore: @MainActor @Sendable (String) -> Void
    public var revealInFinder: @MainActor @Sendable (String) -> Void
    public var openFDASettings: @MainActor @Sendable () -> Void

    public init(
        scan: @escaping @MainActor @Sendable (ScanRoot, ClassifyOptions) -> AsyncStream<ScanEvent> =
            { _, _ in AsyncStream { $0.finish() } },
        cancelScan: @escaping @MainActor @Sendable () -> Void = {},
        loadCached: @escaping @MainActor @Sendable (ScanRoot, ClassifyOptions) async
            -> (StorageTree, StorageTreeOverlay, CleanupSet)? = { _, _ in nil },
        loadSummary: @escaping @MainActor @Sendable () async -> StorageSummary? = { nil },
        reclassify: @escaping @MainActor @Sendable (ClassifyOptions) async -> CleanupSet? = { _ in nil },
        policy: @escaping @MainActor @Sendable () -> StoragePolicy = { .none },
        checkInUse: @escaping @MainActor @Sendable ([CleanupItem]) async -> Set<Int32> = { _ in [] },
        clean: @escaping @MainActor @Sendable ([CleanupItem]) -> AsyncStream<CleanEvent> =
            { _ in AsyncStream { $0.finish() } },
        cancelClean: @escaping @MainActor @Sendable () -> Void = {},
        undo: @escaping @MainActor @Sendable (UndoRecord) -> AsyncStream<CleanEvent> =
            { _ in AsyncStream { $0.finish() } },
        emptyTrash: @escaping @MainActor @Sendable () -> AsyncStream<CleanEvent> = { AsyncStream { $0.finish() } },
        release: @escaping @MainActor @Sendable () -> Void = {},
        availableRoots: @escaping @MainActor @Sendable () -> [ScanRoot] = { [] },
        hasFullDiskAccess: @escaping @MainActor @Sendable () async -> Bool = { true },
        ignore: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        unignore: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        revealInFinder: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        openFDASettings: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.scan = scan
        self.cancelScan = cancelScan
        self.loadCached = loadCached
        self.loadSummary = loadSummary
        self.reclassify = reclassify
        self.policy = policy
        self.checkInUse = checkInUse
        self.clean = clean
        self.cancelClean = cancelClean
        self.undo = undo
        self.emptyTrash = emptyTrash
        self.release = release
        self.availableRoots = availableRoots
        self.hasFullDiskAccess = hasFullDiskAccess
        self.ignore = ignore
        self.unignore = unignore
        self.revealInFinder = revealInFinder
        self.openFDASettings = openFDASettings
    }

    /// Does nothing: streams finish at once, loads return nil, no roots.
    public static let noop = StorageActions()
}
