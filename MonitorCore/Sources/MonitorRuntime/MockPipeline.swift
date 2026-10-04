import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel

/// Wm T4 (ARCHITECTURE §5.11): streams `MockDataProvider` frames into a `LiveModel`, at 1 s while the
/// popover or dashboard is visible and 5 s otherwise (`SamplingMode.interval`, ARCHITECTURE §5.2), and
/// takes no samples while paused. The interval/pause state machine itself (`MockFeeder`) lives in
/// `MonitorMocks`, fully unit-tested there without a timer; this is a thin adapter that owns the actual
/// loop, mirroring the real engine's wake-up pattern (§4): a cancellable sleeper `Task`, recomputed
/// whenever visibility or pause state changes.
@MainActor final class MockPipeline: RuntimePipeline {
    let live: LiveModel
    let history: any HistoryProvider
    let storageActions: StorageActions

    private let feeder: MockFeeder
    private var sleeper: Task<Void, Never>?
    private var started = false

    init(scenario: MockScenario, storage: MockStorageState.Kind = .map) {
        let provider = MockDataProvider(scenario: scenario)
        live = LiveModel(device: provider.device)
        history = provider.history()
        storageActions = provider.storageActions(log: ActionLog(), state: .make(storage))
        feeder = MockFeeder(provider: provider)
    }

    func start() {
        guard !started else { return }
        started = true
        wake(sampleNow: true)
    }

    func setVisibility(_ v: UIVisibility) {
        feeder.setVisibility(v)
        wake(sampleNow: true)
    }

    func setPaused(_ p: Bool) {
        feeder.setPaused(p)
        live.setPaused(p, at: Date())
        wake(sampleNow: !p)
    }

    func systemWillSleep() {}
    func systemDidWake() {}

    func shutdown() async {
        sleeper?.cancel()
        sleeper = nil
    }

    // MARK: - Private

    private func wake(sampleNow: Bool) {
        sleeper?.cancel()
        scheduleNext(sampleNow: sampleNow)
    }

    private func scheduleNext(sampleNow: Bool) {
        guard started else { return }
        if sampleNow { sample() }
        guard let interval = feeder.interval else {
            sleeper = nil   // Paused: no timer at all until `setPaused`/`setVisibility` wakes it again.
            return
        }
        sleeper = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.scheduleNext(sampleNow: true)
        }
    }

    private func sample() {
        guard let frame = feeder.nextFrame() else { return }
        live.apply(frame)
    }
}
