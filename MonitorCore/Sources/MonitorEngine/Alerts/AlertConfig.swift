import MonitorModel

// W0b stub (ARCHITECTURE §5.8). W1 replaces this file.

public struct AlertConfig: Sendable, Equatable {
    /// Ruling: ≥ 100 % …
    public var runawayEnterCPUPercent: Double = 100
    /// … sustained 5 min (every sample in window ≥ threshold).
    public var runawayEnterAfter: Duration = .seconds(300)
    public var runawayExitCPUPercent: Double = 80
    public var runawayExitAfter: Duration = .seconds(30)
    public var stepDownHold: Duration = .seconds(10)
    public var runawayExcluded: Set<AppKey> = [.system, .other]
    public init() {}
}

public struct EpisodeConfig: Sendable {
    public var cpuPercent = 200.0, gpuPercent = 30.0, netBps = 10e6, diskBps = 50e6
    public var minDuration: Duration = .seconds(60), mergeGap: Duration = .seconds(30)
    public init() {}
}
