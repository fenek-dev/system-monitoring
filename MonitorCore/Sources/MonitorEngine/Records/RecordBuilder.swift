import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

public struct RecordConfig: Sendable {
    /// Any GPU > 0 counts.
    public var minCPUPercent = 0.5, minNetBps = 1024.0, minDiskBps = 102_400.0
    public var minMemory: UInt64 = 200 << 20
    public init() {}
}

public struct RecordBuilder: Sendable {
    public init(config: RecordConfig = .init()) {}
    public func record(from frame: SystemFrame) -> HistoryRecord { HistoryRecord() }
}
