import Foundation

public enum CoreKind: String, Sendable, Codable { case performance, efficiency }

public struct CoreTicks: Sendable, Codable, Hashable {
    public var user, system, idle, nice: UInt64

    public init(user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct HostCPUReading: Sendable, Codable {
    public var cores: [CoreTicks]
    public var coreKinds: [CoreKind]
    public var loadAverage: [Double]

    public init(cores: [CoreTicks] = [], coreKinds: [CoreKind] = [], loadAverage: [Double] = []) {
        self.cores = cores
        self.coreKinds = coreKinds
        self.loadAverage = loadAverage
    }
}
