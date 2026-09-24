import Foundation
import MonitorModel

/// Pure decoding of AGXDeviceUserClient registry properties (docs/findings/gpu-apps.md).
/// The sensor reports cumulative counters per client; deltas + reset/pid-reuse guards live in the engine.
enum GPUClientsParse {
    /// `"pid 123, Name"` → (123, "Name"). Name may itself contain commas; split on the first one only.
    static func creator(_ s: String) -> (pid: Int32, name: String)? {
        let parts = s.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        guard head.hasPrefix("pid "), let pid = Int32(head.dropFirst(4).trimmingCharacters(in: .whitespaces)),
              pid >= 0 else { return nil }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (pid, name)
    }

    /// Σ `accumulatedGPUTime` (ns) over the client's `AppUsage` entries. Saturates instead of trapping.
    static func gpuTimeNs(_ appUsage: Any?) -> UInt64 {
        guard let list = appUsage as? [Any] else { return 0 }
        var total: UInt64 = 0
        for case let entry as [String: Any] in list {
            guard let n = entry["accumulatedGPUTime"] as? NSNumber else { continue }
            let (sum, overflow) = total.addingReportingOverflow(n.uint64Value)
            total = overflow ? .max : sum
        }
        return total
    }

    static func client(id: UInt64, creator: Any?, appUsage: Any?) -> GPUClientCounter? {
        guard let s = creator as? String, let c = Self.creator(s) else { return nil }
        return GPUClientCounter(clientID: id, pid: c.pid, creatorName: c.name, gpuTimeNs: gpuTimeNs(appUsage))
    }

    /// `PerformanceStatistics` → (Device Utilization % 0–100, In use system memory bytes).
    static func performance(_ stats: Any?) -> (utilization: Double?, inUseSystemMemory: UInt64?) {
        guard let d = stats as? [String: Any] else { return (nil, nil) }
        let util = (d["Device Utilization %"] as? NSNumber).map { min(100, max(0, $0.doubleValue)) }
        let mem = (d["In use system memory"] as? NSNumber)?.uint64Value
        return (util, mem)
    }
}
