import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.11): empty-default frames for every scenario. Wm replaces this file with real data.

public struct MockDataProvider: Sendable {
    public let scenario: MockScenario
    public let seed: UInt64
    public let start: Date

    public init(scenario: MockScenario, seed: UInt64 = 42, start: Date = MockDataProvider.referenceDate) {
        self.scenario = scenario
        self.seed = seed
        self.start = start
    }

    /// Thu 24 Sep 2026 14:32 local.
    public static let referenceDate: Date = {
        let components = DateComponents(year: 2026, month: 9, day: 24, hour: 14, minute: 32)
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    public var device: DeviceInfo { .placeholder }

    public func frame(at tick: Int) -> SystemFrame {
        SystemFrame(
            wallTime: start.addingTimeInterval(TimeInterval(tick)),
            uptimeNs: UInt64(max(tick, 0)) * 1_000_000_000,
            interval: .seconds(1),
            mode: .interactive,
            device: device
        )
    }

    public func frames(interval: Duration) -> AsyncStream<SystemFrame> {
        AsyncStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    continuation.yield(frame(at: tick))
                    tick += 1
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func history() -> MockHistoryProvider { MockHistoryProvider() }

    public func processActions(log: ActionLog) -> ProcessActions { .noop }
}
