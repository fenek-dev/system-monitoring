import MonitorModel

/// Alert thresholds (ARCHITECTURE §5.8).
public struct AlertConfig: Sendable, Equatable {
    public var runawayEnterCPUPercent: Double = 100          // ruling: ≥ 100 % …
    public var runawayEnterAfter: Duration = .seconds(300)   // … sustained 5 min (every sample in window ≥ threshold)
    public var runawayExitCPUPercent: Double = 80
    public var runawayExitAfter: Duration = .seconds(30)
    public var stepDownHold: Duration = .seconds(10)
    public var runawayExcluded: Set<AppKey> = [.system, .other]

    public init(runawayEnterCPUPercent: Double = 100, runawayEnterAfter: Duration = .seconds(300),
                runawayExitCPUPercent: Double = 80, runawayExitAfter: Duration = .seconds(30),
                stepDownHold: Duration = .seconds(10), runawayExcluded: Set<AppKey> = [.system, .other]) {
        self.runawayEnterCPUPercent = runawayEnterCPUPercent
        self.runawayEnterAfter = runawayEnterAfter
        self.runawayExitCPUPercent = runawayExitCPUPercent
        self.runawayExitAfter = runawayExitAfter
        self.stepDownHold = stepDownHold
        self.runawayExcluded = runawayExcluded
    }
}

/// App episode thresholds (ARCHITECTURE §5.8).
public struct EpisodeConfig: Sendable, Equatable {
    public var cpuPercent = 200.0, gpuPercent = 30.0, netBps = 10e6, diskBps = 50e6
    public var minDuration: Duration = .seconds(60), mergeGap: Duration = .seconds(30)

    public init(cpuPercent: Double = 200.0, gpuPercent: Double = 30.0, netBps: Double = 10e6, diskBps: Double = 50e6,
                minDuration: Duration = .seconds(60), mergeGap: Duration = .seconds(30)) {
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.netBps = netBps
        self.diskBps = diskBps
        self.minDuration = minDuration
        self.mergeGap = mergeGap
    }
}
