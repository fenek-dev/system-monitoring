import Foundation
import MonitorLive
import MonitorModel

// W0b stub (ARCHITECTURE §5.11): engine + SensorFactory.live + HistoryStore. W7 replaces this file.

@MainActor final class LivePipeline: RuntimePipeline {
    let live: LiveModel
    let history: any HistoryProvider

    init(dataDirectory: URL, disabledSensors: Set<SensorID>, crashSensor: SensorID?) {
        live = LiveModel()
        history = EmptyHistoryProvider()
    }

    func start() {}
    func setVisibility(_ v: UIVisibility) {}
    func setPaused(_ p: Bool) {}
    func systemWillSleep() {}
    func systemDidWake() {}
    func shutdown() async {}
}
