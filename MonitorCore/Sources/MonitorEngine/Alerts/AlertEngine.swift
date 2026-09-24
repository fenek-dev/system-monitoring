import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.8). W1 replaces this file.

public struct AlertEngine: Sendable {
    public init(config: AlertConfig = .init()) {
        state = .calm
    }
    public private(set) var state: AlertState
    public mutating func update(thermal: ThermalPressure?, memory: MemoryPressureLevel?, apps: [AppSample],
                                at now: Date) -> (state: AlertState, events: [HistoryEvent]) {
        (state, [])
    }
    public mutating func setPaused(_ paused: Bool, at now: Date) -> AlertState { state }
}
