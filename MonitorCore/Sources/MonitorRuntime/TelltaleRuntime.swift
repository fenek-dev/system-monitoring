import Foundation
import MonitorEngine
import MonitorLive
import MonitorMocks
import MonitorModel

// ARCHITECTURE §5.11. Façade written by W0b; owned by W7.

public enum RuntimeMode: Sendable, Equatable { case live, mock(MockScenario) }

@MainActor public protocol RuntimePipeline: AnyObject {
    var live: LiveModel { get }
    var history: any HistoryProvider { get }
    func start()
    func setVisibility(_ v: UIVisibility)
    func setPaused(_ p: Bool)
    func systemWillSleep()
    func systemDidWake()
    func shutdown() async
    /// false when history could not be stored on disk this launch (in-memory fallback, or none): the History
    /// page shows "History unavailable" (ARCHITECTURE §6).
    var historyPersistent: Bool { get }
    /// Returns once the history store has opened (off the MainActor) and `historyPersistent` is final.
    func historyReady() async
    var storageActions: StorageActions { get }
}

public extension RuntimePipeline {
    /// Mocks and anything without a store fallback: history is available.
    var historyPersistent: Bool { true }
    func historyReady() async {}
}

/// Façade over one `RuntimePipeline` (`LivePipeline` or `MockPipeline`).
@MainActor public final class TelltaleRuntime {
    private let pipeline: any RuntimePipeline
    /// Storage page state; built on the final actions (live: decorated with the AppKit pieces).
    public let storage: StorageModel
    public let storageActions: StorageActions

    /// Mock mode only: the fixture state the Storage model was seeded with (`--mock-storage`); the app opens the
    /// page in Cleanup mode for `.cleanup`.
    public let mockStorageKind: MockStorageState.Kind?

    private init(pipeline: any RuntimePipeline, storageActions: StorageActions, storage: StorageModel? = nil,
                 mockStorageKind: MockStorageState.Kind? = nil) {
        self.pipeline = pipeline
        self.storageActions = storageActions
        self.storage = storage ?? StorageModel(actions: storageActions)
        self.mockStorageKind = mockStorageKind
    }

    /// The model a launch would have after opening the page in `kind`'s state. The mock actions' cache loader
    /// returns nothing for `.empty`/`.scanning`, so those states (and `noFDA`'s missing access) are seeded here;
    /// the scanning scan stream never yields (see `MockPipeline`), so the in-progress state stays put.
    private static func seededMockStorage(_ kind: MockStorageState.Kind, actions: StorageActions) -> StorageModel {
        let state = MockStorageState.make(kind)
        let model = StorageModel(actions: actions, home: MockStorageState.home,
                                 now: { MockDataProvider.referenceDate })
        model.seedAccess(hasFullDiskAccess: state.hasFullDiskAccess, availableRoots: actions.availableRoots())
        switch kind {
        case .empty:
            break
        case .scanning:
            model.startScan()
            if let progress = state.progress { model.apply(.progress(progress)) }
            if let tree = state.tree { model.apply(.partial(tree)) }
        case .map, .cleanup, .noFDA:
            if let tree = state.tree, let overlay = state.overlay, let set = state.cleanup {
                model.adopt(tree: tree, overlay: overlay, cleanup: set)
            }
        }
        return model
    }

    /// crashSensor: DEBUG canary drill.
    /// canarySuite: UserDefaults suite for crash-canary markers (nil = standard defaults). Dev builds pass the
    /// per-data-dir settings suite so worktrees sharing the bundle id don't disable each other's sensors.
    /// storagePlatform / decorateStorageActions: AppKit pieces of the live storage backend (running apps, reveal,
    /// ignore list) built by the app; the decorator runs in `.live` only (mocks bring their own actions).
    public static func make(mode: RuntimeMode, dataDirectory: URL, disabledSensors: Set<SensorID>,
                            crashSensor: SensorID? = nil, canarySuite: String? = nil,
                            storagePlatform: StoragePlatform = .none, mockStorage: MockStorageState.Kind = .map,
                            decorateStorageActions: @MainActor (StorageActions) -> StorageActions = { $0 })
        -> TelltaleRuntime {
        switch mode {
        case .live:
            let pipeline = LivePipeline(dataDirectory: dataDirectory, disabledSensors: disabledSensors,
                                        crashSensor: crashSensor, canarySuite: canarySuite,
                                        storagePlatform: storagePlatform)
            return TelltaleRuntime(pipeline: pipeline, storageActions: decorateStorageActions(pipeline.storageActions))
        case .mock(let scenario):
            let pipeline = MockPipeline(scenario: scenario, storage: mockStorage)
            return TelltaleRuntime(
                pipeline: pipeline, storageActions: pipeline.storageActions,
                storage: seededMockStorage(mockStorage, actions: pipeline.storageActions),
                mockStorageKind: mockStorage)
        }
    }

    /// Settings "Re-enable sensors": clears every crash-canary marker in `canarySuite` (nil = standard defaults),
    /// the same store `make(…, canarySuite:)` reads. Takes effect when the sensors are next built (next launch).
    public nonisolated static func reenableCrashedSensors(canarySuite: String?) {
        canary(suite: canarySuite).reenableAll()
    }

    nonisolated static func canary(suite: String?) -> CrashCanary {
        suite.map(CrashCanary.defaults(suite:)) ?? .standard
    }

    public var live: LiveModel { pipeline.live }
    public var history: any HistoryProvider { pipeline.history }
    /// false → History page banner "History unavailable" (store fell back to memory, §6). The live store opens off
    /// the MainActor: true until `historyReady()` has returned.
    public var historyPersistent: Bool { pipeline.historyPersistent }
    public func historyReady() async { await pipeline.historyReady() }
    public func start() { pipeline.start() }
    public func setVisibility(_ v: UIVisibility) { pipeline.setVisibility(v) }
    public func setPaused(_ p: Bool) { pipeline.setPaused(p) }
    public func systemWillSleep() { pipeline.systemWillSleep() }
    public func systemDidWake() { pipeline.systemDidWake() }
    public func shutdown() async {
        storageActions.cancelClean()
        await pipeline.shutdown()
    }
}
