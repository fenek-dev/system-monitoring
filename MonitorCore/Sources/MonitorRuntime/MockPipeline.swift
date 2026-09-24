import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel

// W0b stub (ARCHITECTURE §5.11): MockDataProvider + MockHistoryProvider. Wm replaces this file.

@MainActor final class MockPipeline: RuntimePipeline {
    let live: LiveModel
    let history: any HistoryProvider

    init(scenario: MockScenario) {
        let provider = MockDataProvider(scenario: scenario)
        live = LiveModel(device: provider.device)
        history = provider.history()
    }

    func start() {}
    func setVisibility(_ v: UIVisibility) {}
    func setPaused(_ p: Bool) {}
    func systemWillSleep() {}
    func systemDidWake() {}
    func shutdown() async {}
}
