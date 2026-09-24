import Foundation

public struct AppSample: Sendable, Codable, Hashable, Identifiable {
    public var id: AppKey { identity.key }
    public var identity: AppIdentity
    public var processIDs: [ProcessID]
    /// Restricted members not individually attributed.
    public var hiddenProcessCount: Int
    /// Share that came from synthetic coalition rows.
    public var coalitionResidual: AppMetrics?
    public var isCurrentUser: Bool
    public var cpuPercent: Double?, gpuPercent: Double?, memory: UInt64?
    public var netRxBps: Double?, netTxBps: Double?, diskReadBps: Double?, diskWriteBps: Double?
    public var energyWatts: Double?, energyEstimated: Bool
    /// Session (since Telltale start).
    public var cpuTimeNs: UInt64?, gpuTimeNs: UInt64?
    /// "This session".
    public var netRxSession: UInt64?, netTxSession: UInt64?
    public var threads: Int32?, connectionCount: Int?, preventsSleep: Bool
    public var metrics: AppMetrics

    public init(
        identity: AppIdentity = AppIdentity(),
        processIDs: [ProcessID] = [],
        hiddenProcessCount: Int = 0,
        coalitionResidual: AppMetrics? = nil,
        isCurrentUser: Bool = false,
        cpuPercent: Double? = nil,
        gpuPercent: Double? = nil,
        memory: UInt64? = nil,
        netRxBps: Double? = nil,
        netTxBps: Double? = nil,
        diskReadBps: Double? = nil,
        diskWriteBps: Double? = nil,
        energyWatts: Double? = nil,
        energyEstimated: Bool = false,
        cpuTimeNs: UInt64? = nil,
        gpuTimeNs: UInt64? = nil,
        netRxSession: UInt64? = nil,
        netTxSession: UInt64? = nil,
        threads: Int32? = nil,
        connectionCount: Int? = nil,
        preventsSleep: Bool = false,
        metrics: AppMetrics = AppMetrics()
    ) {
        self.identity = identity
        self.processIDs = processIDs
        self.hiddenProcessCount = hiddenProcessCount
        self.coalitionResidual = coalitionResidual
        self.isCurrentUser = isCurrentUser
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.memory = memory
        self.netRxBps = netRxBps
        self.netTxBps = netTxBps
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.energyWatts = energyWatts
        self.energyEstimated = energyEstimated
        self.cpuTimeNs = cpuTimeNs
        self.gpuTimeNs = gpuTimeNs
        self.netRxSession = netRxSession
        self.netTxSession = netTxSession
        self.threads = threads
        self.connectionCount = connectionCount
        self.preventsSleep = preventsSleep
        self.metrics = metrics
    }

    /// Live value of `metric` from the typed fields (memory in bytes).
    public func value(for metric: AppMetric) -> Double? {
        switch metric {
        case .cpu: cpuPercent
        case .gpu: gpuPercent
        case .memory: memory.map { Double($0) }
        case .netRx: netRxBps
        case .netTx: netTxBps
        case .diskRead: diskReadBps
        case .diskWrite: diskWriteBps
        case .energy: energyWatts
        }
    }
}
