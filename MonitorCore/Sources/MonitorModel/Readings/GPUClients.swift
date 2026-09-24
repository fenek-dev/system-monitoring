import Foundation

public struct GPUClientCounter: Sendable, Codable, Hashable {
    /// IORegistry entry ID of the AGXDeviceUserClient.
    public var clientID: UInt64
    public var pid: Int32
    /// From "pid 123, Name".
    public var creatorName: String
    /// Σ AppUsage.accumulatedGPUTime for this client.
    public var gpuTimeNs: UInt64

    public init(clientID: UInt64 = 0, pid: Int32 = 0, creatorName: String = "", gpuTimeNs: UInt64 = 0) {
        self.clientID = clientID
        self.pid = pid
        self.creatorName = creatorName
        self.gpuTimeNs = gpuTimeNs
    }
}

public struct GPUClientsReading: Sendable, Codable {
    public var clients: [GPUClientCounter]
    /// AGX `PerformanceStatistics["Device Utilization %"]` (0–100). FALLBACK ONLY: the driver computes it
    /// over the window since the previous read by ANY reader (Activity Monitor, ioreg, …), so back-to-back
    /// reads return 0. System GPU % comes from `SoCPowerReading.gpuActiveFraction` (IOReport residency);
    /// per-app shares from `clients` time deltas (ruling 2026-09-24, W6b).
    public var deviceUtilization: Double?
    /// AGX `In use system memory` (bytes).
    public var inUseSystemMemory: UInt64?

    public init(clients: [GPUClientCounter] = [], deviceUtilization: Double? = nil, inUseSystemMemory: UInt64? = nil) {
        self.clients = clients
        self.deviceUtilization = deviceUtilization
        self.inUseSystemMemory = inUseSystemMemory
    }
}
