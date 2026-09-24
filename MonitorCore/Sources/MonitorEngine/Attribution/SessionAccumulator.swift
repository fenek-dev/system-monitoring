import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

/// Per AppKey since launch: cpuTimeNs, gpuTimeNs, net rx/tx.
public struct SessionAccumulator: Sendable {
    public init() {}
    public mutating func add(_ apps: [AppSample], processDeltas: [ProcessID: (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64)]) {}
    public func totals(_ key: AppKey) -> (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64) { (0, 0, 0, 0) }
}
