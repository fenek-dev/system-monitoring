import Foundation

public struct ProcessSample: Sendable, Codable, Hashable, Identifiable {
    public var id: ProcessID
    public var pid: Int32 { id.pid }
    public var name: String, path: String?, user: String?, uid: UInt32
    public var isCurrentUser: Bool
    public var app: AppKey
    public var provenance: Provenance
    public var coalitionID: UInt64?
    /// `p_comm` of the coalition leader (ICR-4), for "counted in the ‹leader› coalition row"; nil if unknown.
    public var coalitionLeaderName: String?
    public var cpuPercent: Double?, cpuTimeNs: UInt64?, threads: Int32?
    public var memory: UInt64?, memorySource: MemorySource?
    public var gpuPercent: Double?, gpuTimeNs: UInt64?
    public var netRxBps: Double?, netTxBps: Double?, netRxTotal: UInt64?, netTxTotal: UInt64?, connectionCount: Int?
    public var diskReadBps: Double?, diskWriteBps: Double?, diskReadTotal: UInt64?, diskWriteTotal: UInt64?
    public var energyWatts: Double?, energyEstimated: Bool
    public var preventsSleep: Bool
    /// ICR-14: disk bytes since Telltale started (`diskReadTotal`/`diskWriteTotal` stay lifetime counters).
    public var diskReadSession: UInt64?, diskWriteSession: UInt64?

    public init(
        id: ProcessID = ProcessID(),
        name: String = "",
        path: String? = nil,
        user: String? = nil,
        uid: UInt32 = 0,
        isCurrentUser: Bool = false,
        app: AppKey = .system,
        provenance: Provenance = .measured,
        coalitionID: UInt64? = nil,
        coalitionLeaderName: String? = nil,
        cpuPercent: Double? = nil,
        cpuTimeNs: UInt64? = nil,
        threads: Int32? = nil,
        memory: UInt64? = nil,
        memorySource: MemorySource? = nil,
        gpuPercent: Double? = nil,
        gpuTimeNs: UInt64? = nil,
        netRxBps: Double? = nil,
        netTxBps: Double? = nil,
        netRxTotal: UInt64? = nil,
        netTxTotal: UInt64? = nil,
        connectionCount: Int? = nil,
        diskReadBps: Double? = nil,
        diskWriteBps: Double? = nil,
        diskReadTotal: UInt64? = nil,
        diskWriteTotal: UInt64? = nil,
        energyWatts: Double? = nil,
        energyEstimated: Bool = false,
        preventsSleep: Bool = false,
        diskReadSession: UInt64? = nil,
        diskWriteSession: UInt64? = nil
    ) {
        self.diskReadSession = diskReadSession
        self.diskWriteSession = diskWriteSession
        self.id = id
        self.name = name
        self.path = path
        self.user = user
        self.uid = uid
        self.isCurrentUser = isCurrentUser
        self.app = app
        self.provenance = provenance
        self.coalitionID = coalitionID
        self.coalitionLeaderName = coalitionLeaderName
        self.cpuPercent = cpuPercent
        self.cpuTimeNs = cpuTimeNs
        self.threads = threads
        self.memory = memory
        self.memorySource = memorySource
        self.gpuPercent = gpuPercent
        self.gpuTimeNs = gpuTimeNs
        self.netRxBps = netRxBps
        self.netTxBps = netTxBps
        self.netRxTotal = netRxTotal
        self.netTxTotal = netTxTotal
        self.connectionCount = connectionCount
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.diskReadTotal = diskReadTotal
        self.diskWriteTotal = diskWriteTotal
        self.energyWatts = energyWatts
        self.energyEstimated = energyEstimated
        self.preventsSleep = preventsSleep
    }

    /// Live value of an app metric for this row (same mapping as `AppSample.value(for:)`).
    func value(for metric: AppMetric) -> Double? {
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
