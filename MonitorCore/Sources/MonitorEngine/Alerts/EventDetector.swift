import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.8). W1 replaces this file.

public struct EventDetector: Sendable {
    public init(config: EpisodeConfig = .init()) {}
    public mutating func update(_ frame: SystemFrame) -> [HistoryEvent] { [] }
    public mutating func flush(at: Date) -> [HistoryEvent] { [] }
}
