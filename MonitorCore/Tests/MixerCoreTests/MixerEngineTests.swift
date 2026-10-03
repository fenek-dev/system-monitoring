import Foundation
import Testing
@testable import MixerCore

final class FakeController: VolumeControlling {
    let objectIDs: [UInt32]
    var gains: [Float]
    var invalidated = false

    init(objectIDs: [UInt32], gain: Float) {
        self.objectIDs = objectIDs
        gains = [gain]
    }

    func setGain(_ gain: Float) { gains.append(gain) }
    func invalidate() { invalidated = true }
}

final class FakeFactory {
    struct Failure: Error {}
    var created: [FakeController] = []
    var failing: Set<[UInt32]> = []
    var attempts = 0
    /// Number of live controllers at the moment of each attempt.
    var liveAtAttempt: [Int] = []

    func make(objectIDs: [UInt32], gain: Float) throws -> VolumeControlling {
        attempts += 1
        liveAtAttempt.append(live.count)
        if failing.contains(objectIDs) { throw Failure() }
        let controller = FakeController(objectIDs: objectIDs, gain: gain)
        created.append(controller)
        return controller
    }

    var live: [FakeController] { created.filter { !$0.invalidated } }
}

final class FakePermissions: PermissionProviding {
    var state: PermissionState
    var requests = 0
    var pending: ((Bool) -> Void)?

    init(_ state: PermissionState) { self.state = state }

    func request(_ completion: @escaping (Bool) -> Void) {
        requests += 1
        pending = completion
    }
}

@MainActor
struct MixerEngineTests {
    let defaults = UserDefaults(suiteName: "MixerEngineTests-\(UUID().uuidString)")!
    let factory = FakeFactory()

    private func engine(_ permissions: FakePermissions = FakePermissions(.granted)) -> MixerEngine {
        MixerEngine(
            store: VolumeStore(defaults: defaults),
            permissions: permissions,
            describe: { AppDescription(name: $0.uppercased(), bundleURL: nil) },
            factory: factory.make)
    }

    private func group(_ id: String, _ objectIDs: [UInt32] = [1], playing: Bool = false, regular: Bool = true) -> AppGroup {
        AppGroup(id: id, objectIDs: objectIDs, isPlaying: playing, isRegularApp: regular)
    }

    @Test func fullVolumeCreatesNoController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        #expect(factory.attempts == 0)
        #expect(engine.rows.map(\.id) == ["a"])
    }

    @Test func loweringVolumeCreatesControllerWithCurvedGain() {
        let engine = engine()
        engine.update(groups: [group("a", [3, 4])])
        engine.setVolume(0.5, for: "a")
        #expect(factory.created.count == 1)
        #expect(factory.created[0].objectIDs == [3, 4])
        #expect(factory.created[0].gains == [0.25])
        #expect(engine.rows[0].setting.volume == 0.5)
    }

    @Test func furtherChangesReuseController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.1, for: "a")
        #expect(factory.created.count == 1)
        #expect(factory.created[0].gains.count == 2)
        #expect(abs(factory.created[0].gains[1] - 0.01) < 1e-6)
    }

    @Test func returningToFullVolumeInvalidates() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(1, for: "a")
        #expect(factory.created[0].invalidated)
        #expect(factory.live.isEmpty)
    }

    @Test func muteZeroesGainAndKeepsVolume() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setMuted(true, for: "a")
        #expect(factory.created[0].gains.last == 0)
        #expect(engine.rows[0].setting == AppVolume(volume: 0.5, muted: true))
        engine.setMuted(false, for: "a")
        #expect(factory.created[0].gains.last == 0.25)
    }

    @Test func muteAtFullVolumeCreatesController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setMuted(true, for: "a")
        #expect(factory.live.count == 1)
        #expect(factory.live[0].gains == [0])
    }

    @Test func savedVolumeAppliesWhenAppAppears() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.5), for: "a")
        let engine = engine()
        #expect(factory.attempts == 0)
        #expect(engine.rows.map(\.id) == ["a"])
        #expect(engine.rows[0].isRunning == false)
        engine.update(groups: [group("a")])
        #expect(factory.live.count == 1)
        #expect(engine.rows[0].isRunning)
    }

    @Test func appQuitInvalidatesAndKeepsDimmedRow() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.update(groups: [])
        #expect(factory.created[0].invalidated)
        #expect(engine.rows.map(\.id) == ["a"])
        #expect(engine.rows[0].isRunning == false)
    }

    @Test func changedProcessSetRebuildsController() {
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.setVolume(0.5, for: "a")
        engine.update(groups: [group("a", [1, 2])])
        #expect(factory.created.count == 2)
        #expect(factory.created[0].invalidated)
        #expect(factory.created[1].objectIDs == [1, 2])
    }

    /// Destroying the old tap first would let the app play at full volume until the new one starts.
    @Test func replacementStartsBeforeOldControllerStops() {
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.setMuted(true, for: "a")
        engine.update(groups: [group("a", [1, 2])])
        #expect(factory.liveAtAttempt == [0, 1])
        #expect(factory.live.map(\.objectIDs) == [[1, 2]])
    }

    @Test func deviceChangeStartsReplacementBeforeOldControllerStops() {
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.setMuted(true, for: "a")
        engine.outputDeviceChanged()
        #expect(factory.liveAtAttempt == [0, 1])
        #expect(factory.live.count == 1)
    }

    @Test func failedReplacementKeepsOldControllerWorking() {
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.setVolume(0.5, for: "a")
        factory.failing = [[1, 2]]
        engine.update(groups: [group("a", [1, 2])])
        #expect(factory.created[0].invalidated == false)
        #expect(engine.rows[0].failed)
        engine.setMuted(true, for: "a")
        #expect(factory.created[0].gains.last == 0)
    }

    @Test func failedRebuildAfterDeviceChangeStopsOldController() {
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.setVolume(0.5, for: "a")
        factory.failing = [[1]]
        engine.outputDeviceChanged()
        #expect(factory.created[0].invalidated)
        #expect(engine.rows[0].failed)
    }

    @Test func unchangedUpdateDoesNotRebuild() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.update(groups: [group("a", playing: true)])
        #expect(factory.created.count == 1)
    }

    @Test func outputDeviceChangeRebuildsAll() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.5, for: "b")
        engine.outputDeviceChanged()
        #expect(factory.created.count == 4)
        #expect(factory.live.count == 2)
    }

    @Test func failureFlagsOnlyThatRowAndRetriesOnUserChange() {
        let engine = engine()
        factory.failing = [[1]]
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.5, for: "b")
        #expect(engine.rows.first { $0.id == "a" }?.failed == true)
        #expect(engine.rows.first { $0.id == "b" }?.failed == false)
        #expect(factory.live.map(\.objectIDs) == [[2]])

        let attempts = factory.attempts
        engine.update(groups: [group("a", [1], playing: true), group("b", [2])])
        #expect(factory.attempts == attempts)

        factory.failing = []
        engine.setVolume(0.4, for: "a")
        #expect(engine.rows.first { $0.id == "a" }?.failed == false)
        #expect(factory.live.count == 2)
    }

    @Test func deniedPermissionCreatesNothingUntilGranted() {
        let permissions = FakePermissions(.denied)
        let engine = engine(permissions)
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        #expect(factory.attempts == 0)
        #expect(engine.permission == .denied)
        #expect(permissions.requests == 0)

        permissions.state = .granted
        engine.refreshPermission()
        #expect(engine.permission == .granted)
        #expect(factory.live.count == 1)
    }

    @Test func unknownPermissionRequestsOnceThenApplies() {
        let permissions = FakePermissions(.unknown)
        let engine = engine(permissions)
        engine.update(groups: [group("a")])
        #expect(permissions.requests == 0)
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.4, for: "a")
        #expect(permissions.requests == 1)
        #expect(factory.attempts == 0)

        permissions.pending?(true)
        #expect(engine.permission == .granted)
        #expect(factory.live.count == 1)
    }

    @Test func refusedRequestMarksDenied() {
        let permissions = FakePermissions(.unknown)
        let engine = engine(permissions)
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        permissions.pending?(false)
        #expect(engine.permission == .denied)
        #expect(factory.attempts == 0)
    }

    @Test func rowsSortPlayingThenRunningThenName() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.5), for: "idle")
        let engine = engine()
        engine.update(groups: [group("zeta"), group("beta", [2], playing: true), group("alpha", [3])])
        #expect(engine.rows.map(\.id) == ["beta", "alpha", "zeta", "idle"])
    }

    @Test func boostCreatesControllerAboveUnity() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(1.5, for: "a")
        #expect(factory.live.count == 1)
        #expect(factory.live[0].gains == [2.25])
    }

    @Test func soloSilencesOtherVisibleApps() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("b", [2]), group("c", [3], playing: true, regular: false)])
        engine.solo("a")
        #expect(engine.soloID == "a")
        #expect(factory.live.map(\.objectIDs).sorted { $0[0] < $1[0] } == [[2], [3]])
        #expect(factory.live.allSatisfy { $0.gains == [0] })
        #expect(engine.rows.first { $0.id == "b" }?.silenced == true)
        #expect(engine.rows.first { $0.id == "a" }?.silenced == false)
    }

    @Test func soloLeavesSilentBackgroundProcessesAlone() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("daemon", [9], regular: false)])
        engine.solo("a")
        #expect(factory.attempts == 0)
    }

    @Test func soloDoesNotChangeSavedVolumes() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.setVolume(0.5, for: "b")
        engine.solo("a")
        #expect(factory.created[0].gains.last == 0)
        #expect(engine.rows.first { $0.id == "b" }?.setting == AppVolume(volume: 0.5))
        #expect(VolumeStore(defaults: defaults).all == ["b": AppVolume(volume: 0.5)])
    }

    @Test func endingSoloRestoresPreviousLevels() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("b", [2]), group("c", [3])])
        engine.setVolume(0.5, for: "b")
        engine.solo("a")
        engine.solo(nil)
        #expect(engine.soloID == nil)
        #expect(factory.live.map(\.objectIDs) == [[2]])
        #expect(factory.live[0].gains.last == 0.25)
        #expect(engine.rows.allSatisfy { !$0.silenced })
    }

    @Test func soloEndsWhenSoloedAppQuits() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.solo("a")
        engine.update(groups: [group("b", [2])])
        #expect(engine.soloID == nil)
        #expect(factory.live.isEmpty)
    }

    /// Soloing an app that makes no sound would silence everything with nothing left audible.
    @Test func soloOnAppWithoutAudioIsIgnored() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.5), for: "idle")
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.solo("idle")
        #expect(engine.soloID == nil)
        #expect(factory.attempts == 0)
    }

    @Test func soloWithoutPermissionIsIgnored() {
        let engine = engine(FakePermissions(.denied))
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.solo("a")
        #expect(engine.soloID == nil)
        #expect(engine.rows.allSatisfy { !$0.silenced })
    }

    /// A row must not claim to be silenced while its app is still audible.
    @Test func rowIsNotMarkedSilencedWhenItsTapFailed() {
        let engine = engine()
        factory.failing = [[2]]
        engine.update(groups: [group("a", [1]), group("b", [2]), group("c", [3])])
        engine.solo("a")
        #expect(engine.rows.first { $0.id == "b" }?.silenced == false)
        #expect(engine.rows.first { $0.id == "b" }?.failed == true)
        #expect(engine.rows.first { $0.id == "c" }?.silenced == true)
    }

    @Test func hidingMarksRowAndKeepsItsController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setHidden(true, for: "a")
        #expect(engine.rows.first { $0.id == "a" }?.hidden == true)
        #expect(factory.live.count == 1)
        engine.setHidden(false, for: "a")
        #expect(engine.rows.first { $0.id == "a" }?.hidden == false)
    }

    @Test func resetRestoresFullVolumeAndUnmutes() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setMuted(true, for: "a")
        engine.reset("a")
        #expect(engine.rows[0].setting == AppVolume())
        #expect(factory.live.isEmpty)
        #expect(VolumeStore(defaults: defaults).all.isEmpty)
    }

    @Test func silentBackgroundProcessIsHiddenButPlayingOneShows() {
        let engine = engine()
        engine.update(groups: [group("daemon", regular: false)])
        #expect(engine.rows.isEmpty)
        engine.update(groups: [group("daemon", playing: true, regular: false)])
        #expect(engine.rows.map(\.id) == ["daemon"])
    }
}
