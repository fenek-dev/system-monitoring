import Foundation
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
}

/// Façade over one `RuntimePipeline` (`LivePipeline` or `MockPipeline`).
@MainActor public final class TelltaleRuntime {
    private let pipeline: any RuntimePipeline

    private init(pipeline: any RuntimePipeline) {
        self.pipeline = pipeline
    }

    /// crashSensor: DEBUG canary drill.
    public static func make(mode: RuntimeMode, dataDirectory: URL, disabledSensors: Set<SensorID>,
                            crashSensor: SensorID? = nil) -> TelltaleRuntime {
        switch mode {
        case .live:
            TelltaleRuntime(pipeline: LivePipeline(dataDirectory: dataDirectory, disabledSensors: disabledSensors,
                                                   crashSensor: crashSensor))
        case .mock(let scenario):
            TelltaleRuntime(pipeline: MockPipeline(scenario: scenario))
        }
    }

    public var live: LiveModel { pipeline.live }
    public var history: any HistoryProvider { pipeline.history }
    public func start() { pipeline.start() }
    public func setVisibility(_ v: UIVisibility) { pipeline.setVisibility(v) }
    public func setPaused(_ p: Bool) { pipeline.setPaused(p) }
    public func systemWillSleep() { pipeline.systemWillSleep() }
    public func systemDidWake() { pipeline.systemDidWake() }
    public func shutdown() async { await pipeline.shutdown() }
}
