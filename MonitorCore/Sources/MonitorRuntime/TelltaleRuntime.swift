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
}

public extension RuntimePipeline {
    /// Mocks and anything without a store fallback: history is available.
    var historyPersistent: Bool { true }
}

/// Façade over one `RuntimePipeline` (`LivePipeline` or `MockPipeline`).
@MainActor public final class TelltaleRuntime {
    private let pipeline: any RuntimePipeline

    private init(pipeline: any RuntimePipeline) {
        self.pipeline = pipeline
    }

    /// crashSensor: DEBUG canary drill.
    /// canarySuite: UserDefaults suite for crash-canary markers (nil = standard defaults). Dev builds pass the
    /// per-data-dir settings suite so worktrees sharing the bundle id don't disable each other's sensors.
    public static func make(mode: RuntimeMode, dataDirectory: URL, disabledSensors: Set<SensorID>,
                            crashSensor: SensorID? = nil, canarySuite: String? = nil) -> TelltaleRuntime {
        switch mode {
        case .live:
            TelltaleRuntime(pipeline: LivePipeline(dataDirectory: dataDirectory, disabledSensors: disabledSensors,
                                                   crashSensor: crashSensor, canarySuite: canarySuite))
        case .mock(let scenario):
            TelltaleRuntime(pipeline: MockPipeline(scenario: scenario))
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
    /// false → History page banner "History unavailable" (store fell back to memory, §6).
    public var historyPersistent: Bool { pipeline.historyPersistent }
    public func start() { pipeline.start() }
    public func setVisibility(_ v: UIVisibility) { pipeline.setVisibility(v) }
    public func setPaused(_ p: Bool) { pipeline.setPaused(p) }
    public func systemWillSleep() { pipeline.systemWillSleep() }
    public func systemDidWake() { pipeline.systemDidWake() }
    public func shutdown() async { await pipeline.shutdown() }
}
