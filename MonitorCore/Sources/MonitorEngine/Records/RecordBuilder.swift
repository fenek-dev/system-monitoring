import Foundation
import MonitorModel

/// An app is recorded individually when any threshold is met; the rest fold into `.other`.
public struct RecordConfig: Sendable, Equatable {
    public var minCPUPercent = 0.5, minNetBps = 1024.0, minDiskBps = 102_400.0   // any GPU > 0 counts
    public var minMemory: UInt64 = 200 << 20

    public init(minCPUPercent: Double = 0.5, minNetBps: Double = 1024.0, minDiskBps: Double = 102_400.0,
                minMemory: UInt64 = 200 << 20) {
        self.minCPUPercent = minCPUPercent
        self.minNetBps = minNetBps
        self.minDiskBps = minDiskBps
        self.minMemory = minMemory
    }
}

/// `SystemFrame` → `HistoryRecord`: system metrics + apps above the thresholds + one `.other` aggregate.
public struct RecordBuilder: Sendable {
    public let config: RecordConfig

    public init(config: RecordConfig = .init()) {
        self.config = config
    }

    public func record(from frame: SystemFrame) -> HistoryRecord {
        var apps: [AppRecord] = []
        var other: AppMetrics?
        for a in frame.apps {
            // AppGrouper already filled `metrics` (no per-app vector rebuilt per tick); recompute only for a
            // hand-built sample (tests, replays) that left it empty.
            let m = AppMetric.allCases.contains { a.metrics[$0] != nil } ? a.metrics : AppGrouper.metrics(of: a)
            if a.identity.key != .other, qualifies(a) {
                apps.append(AppRecord(identity: a.identity, metrics: m))
            } else {
                var o = other ?? AppMetrics()
                for metric in AppMetric.allCases {
                    if let v = m[metric] { o[metric] = (o[metric] ?? 0) + v }
                }
                other = o
            }
        }
        // No `.other` row when nothing folded carried a value.
        if let other, other != AppMetrics() { apps.append(AppRecord(identity: .other, metrics: other)) }
        // interval_ms is NOMINAL (the mode's cadence), never the measured frame interval (ruling).
        return HistoryRecord(time: frame.wallTime, interval: frame.mode.interval ?? .zero,
                             system: frame.metrics, apps: apps)
    }

    func qualifies(_ a: AppSample) -> Bool {
        if (a.cpuPercent ?? 0) >= config.minCPUPercent { return true }
        if (a.gpuPercent ?? 0) > 0 { return true }
        if (a.netRxBps ?? 0) + (a.netTxBps ?? 0) >= config.minNetBps { return true }
        if (a.diskReadBps ?? 0) + (a.diskWriteBps ?? 0) >= config.minDiskBps { return true }
        if (a.memory ?? 0) >= config.minMemory { return true }
        return false
    }
}
