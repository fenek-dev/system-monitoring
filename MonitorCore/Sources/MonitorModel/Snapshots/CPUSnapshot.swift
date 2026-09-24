import Foundation

public struct CoreUsage: Sendable, Codable, Hashable {
    public var index: Int
    public var kind: CoreKind
    public var usage: Double

    public init(index: Int = 0, kind: CoreKind = .performance, usage: Double = 0) {
        self.index = index
        self.kind = kind
        self.usage = usage
    }
}

public struct ClusterSnapshot: Sendable, Codable, Hashable {
    public var kind: ClusterKind, coreCount: Int
    public var usage: Double?, activeResidency: Double?, frequencyMHz: Double?, maxFrequencyMHz: Double?, watts: Double?

    public init(
        kind: ClusterKind = .performance,
        coreCount: Int = 0,
        usage: Double? = nil,
        activeResidency: Double? = nil,
        frequencyMHz: Double? = nil,
        maxFrequencyMHz: Double? = nil,
        watts: Double? = nil
    ) {
        self.kind = kind
        self.coreCount = coreCount
        self.usage = usage
        self.activeResidency = activeResidency
        self.frequencyMHz = frequencyMHz
        self.maxFrequencyMHz = maxFrequencyMHz
        self.watts = watts
    }
}

public struct CPUSnapshot: Sendable, Codable, Equatable {
    public var usage: Double?, user: Double?, system: Double?, idle: Double?
    /// Only with `.perCore`.
    public var cores: [CoreUsage]
    public var clusters: [ClusterSnapshot]
    public var loadAverage: [Double]?, threadCount: Int?, processCount: Int?

    public init(
        usage: Double? = nil,
        user: Double? = nil,
        system: Double? = nil,
        idle: Double? = nil,
        cores: [CoreUsage] = [],
        clusters: [ClusterSnapshot] = [],
        loadAverage: [Double]? = nil,
        threadCount: Int? = nil,
        processCount: Int? = nil
    ) {
        self.usage = usage
        self.user = user
        self.system = system
        self.idle = idle
        self.cores = cores
        self.clusters = clusters
        self.loadAverage = loadAverage
        self.threadCount = threadCount
        self.processCount = processCount
    }
}
