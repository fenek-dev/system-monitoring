import Foundation
import Observation

public protocol VolumeControlling: AnyObject {
    func setGain(_ gain: Float)
    func invalidate()
}

public typealias ControllerFactory = (_ objectIDs: [UInt32], _ gain: Float) throws -> VolumeControlling

public enum PermissionState: Sendable {
    case unknown, granted, denied
}

public protocol PermissionProviding {
    var state: PermissionState { get }
    /// Completion is called on the main thread.
    func request(_ completion: @escaping (Bool) -> Void)
}

public struct AppDescription: Equatable {
    public let name: String
    public let bundleURL: URL?

    public init(name: String, bundleURL: URL?) {
        self.name = name
        self.bundleURL = bundleURL
    }
}

@MainActor
@Observable
public final class MixerEngine {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let bundleURL: URL?
        public let isPlaying: Bool
        public let isRunning: Bool
        public let setting: AppVolume
        public let failed: Bool
        /// Removed from the list by the user; shown only on request.
        public let hidden: Bool
        /// Silenced because another app is soloed. The saved setting is unchanged.
        public let silenced: Bool
    }

    public private(set) var rows: [Row] = []
    public private(set) var permission: PermissionState
    /// The one app left audible while every other listed app is silenced.
    public private(set) var soloID: String?

    @ObservationIgnored private let store: VolumeStore
    @ObservationIgnored private let permissions: PermissionProviding
    @ObservationIgnored private let describe: (String) -> AppDescription
    @ObservationIgnored private let factory: ControllerFactory
    @ObservationIgnored private var groups: [String: AppGroup] = [:]
    @ObservationIgnored private var controllers: [String: (controller: VolumeControlling, objectIDs: [UInt32])] = [:]
    @ObservationIgnored private var failed: [String: [UInt32]] = [:]
    @ObservationIgnored private var requesting = false

    public init(
        store: VolumeStore,
        permissions: PermissionProviding,
        describe: @escaping (String) -> AppDescription,
        factory: @escaping ControllerFactory
    ) {
        self.store = store
        self.permissions = permissions
        self.describe = describe
        self.factory = factory
        permission = permissions.state
        reconcileAll()
    }

    public func update(groups newGroups: [AppGroup]) {
        groups = Dictionary(newGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Otherwise everything stays silent with nothing audible left to explain it.
        if let soloID, groups[soloID] == nil { self.soloID = nil }
        reconcileAll()
    }

    public func setVolume(_ volume: Float, for id: String) {
        store.set(AppVolume(volume: volume, muted: store.volume(for: id).muted), for: id)
        userChanged(id)
    }

    public func setMuted(_ muted: Bool, for id: String) {
        store.set(AppVolume(volume: store.volume(for: id).volume, muted: muted), for: id)
        userChanged(id)
    }

    /// Back to the app's own level, unmuted. Forgets the saved setting.
    public func reset(_ id: String) {
        store.set(AppVolume(), for: id)
        userChanged(id)
    }

    /// Silences every other listed app until called with nil. Saved volumes are not changed.
    public func solo(_ id: String?) {
        // An app with no audio, or no way to silence the others, would leave a solo that lies.
        if let id, groups[id] == nil || permission == .denied { return }
        soloID = id
        reconcileAll()
    }

    public func setHidden(_ hidden: Bool, for id: String) {
        store.setHidden(hidden, for: id)
        rebuildRows()
    }

    public func outputDeviceChanged() {
        // An empty process set never matches a live group, so every controller is replaced.
        controllers = controllers.mapValues { ($0.controller, []) }
        failed = [:]
        reconcileAll()
    }

    /// Picks up a grant or revocation made in System Settings.
    public func refreshPermission() {
        let current = permissions.state
        if current != .unknown, current != permission { permission = current }
        reconcileAll()
    }

    private func userChanged(_ id: String) {
        failed[id] = nil
        reconcile(id)
        rebuildRows()
    }

    private func reconcileAll() {
        for id in Set(groups.keys).union(controllers.keys).union(store.all.keys) {
            reconcile(id)
        }
        rebuildRows()
    }

    private func isVisible(_ group: AppGroup) -> Bool {
        group.isRegularApp || group.isPlaying
    }

    private func isSilenced(_ id: String) -> Bool {
        guard let soloID, id != soloID, let group = groups[id] else { return false }
        return isVisible(group)
    }

    private func reconcile(_ id: String) {
        let setting = store.volume(for: id)
        let silenced = isSilenced(id)
        let objectIDs = groups[id]?.objectIDs ?? []
        guard silenced || !setting.isDefault, !objectIDs.isEmpty else {
            drop(id)
            failed[id] = nil
            return
        }
        guard hasPermission() else {
            drop(id)
            return
        }
        let gain = silenced ? 0 : Gain.gain(for: setting)
        let existing = controllers[id]
        existing?.controller.setGain(gain)
        if existing?.objectIDs == objectIDs { return }
        if failed[id] == objectIDs { return }
        // Start the replacement before stopping the old tap: the reverse order lets the app
        // play at full volume in between.
        do {
            let replacement = try factory(objectIDs, gain)
            existing?.controller.invalidate()
            controllers[id] = (replacement, objectIDs)
            failed[id] = nil
        } catch {
            failed[id] = objectIDs
            // A controller on the previous output device would keep the app muted on the new one.
            if existing?.objectIDs.isEmpty == true { drop(id) }
        }
    }

    private func drop(_ id: String) {
        controllers.removeValue(forKey: id)?.controller.invalidate()
    }

    private func hasPermission() -> Bool {
        switch permission {
        case .granted:
            return true
        case .denied:
            return false
        case .unknown:
            if !requesting {
                requesting = true
                permissions.request { [weak self] granted in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.requesting = false
                        self.permission = granted ? .granted : .denied
                        self.reconcileAll()
                    }
                }
            }
            return false
        }
    }

    private func rebuildRows() {
        let visible = groups.values.filter(isVisible).map(\.id)
        let ids = Set(visible).union(store.all.keys)
        let hidden = store.hidden
        let updated = ids.map { id -> Row in
            let description = describe(id)
            let group = groups[id]
            return Row(
                id: id,
                name: description.name,
                bundleURL: description.bundleURL,
                isPlaying: group?.isPlaying ?? false,
                isRunning: group != nil,
                setting: store.volume(for: id),
                failed: failed[id] != nil,
                hidden: hidden.contains(id),
                // Only when a tap is really holding it at zero.
                silenced: isSilenced(id) && controllers[id] != nil)
        }
        .sorted { first, second in
            if first.isPlaying != second.isPlaying { return first.isPlaying }
            if first.isRunning != second.isRunning { return first.isRunning }
            let order = first.name.localizedCaseInsensitiveCompare(second.name)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
        if updated != rows { rows = updated }
    }
}
