import Darwin
import Foundation
import MonitorModel

/// Session start (ruling): Telltale's own process start, `p_starttime` of `getpid()` in µs since epoch. Session
/// totals (CPU, network, disk) count usage from here.
public enum SessionStart {
    public static let ownProcessStartUs: UInt64 = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return UInt64(max(0, Date().timeIntervalSince1970 * 1e6))
        }
        let t = info.kp_proc.p_un.__p_starttime
        return UInt64(max(0, t.tv_sec)) * 1_000_000 + UInt64(max(0, t.tv_usec))
    }()
}

/// ICR-14: per-process disk bytes since Telltale started. Baseline per `ProcessID` at first sight: 0 for a process
/// that started at/after the session start (all its I/O is this session's), otherwise its counter then (exact to one
/// tick: processes are sampled from launch). A counter going backwards rebases and carries what was already counted,
/// so the value never drops. Baselines survive sleep/wake (`FrameAssembler.reset`) and are dropped on exit.
struct DiskSessionBaselines: Sendable {
    private struct Counter: Sendable {
        var base: UInt64
        var carried: UInt64 = 0          // counted before the last rebase
        var last: UInt64

        mutating func session(_ counter: UInt64) -> UInt64 {
            if counter < last {                              // went backwards: rebase, keep what was counted
                carried = carried &+ (last - base)
                base = counter
            }
            last = counter
            return carried &+ (counter - base)
        }
    }
    private struct Baseline: Sendable { var read: Counter?, write: Counter? }

    let sessionStartUs: UInt64
    private var baselines: [ProcessID: Baseline] = [:]

    init(sessionStartUs: UInt64) {
        self.sessionStartUs = sessionStartUs
    }

    /// Session bytes for `p`'s counters (nil where the counter is nil).
    mutating func session(_ p: RawProcess) -> (read: UInt64?, write: UInt64?) {
        let newborn = p.id.startTimeUs >= sessionStartUs
        var b = baselines[p.id] ?? Baseline()
        func value(_ counter: UInt64?, _ c: inout Counter?) -> UInt64? {
            guard let counter else { return nil }
            if c == nil { c = Counter(base: newborn ? 0 : counter, last: counter) }
            return c!.session(counter)
        }
        let r = value(p.diskReadBytes, &b.read)
        let w = value(p.diskWriteBytes, &b.write)
        baselines[p.id] = b
        return (r, w)
    }

    mutating func prune(keeping live: Set<ProcessID>) {
        for id in baselines.keys.filter({ !live.contains($0) }) { baselines[id] = nil }
    }

    var count: Int { baselines.count }
}
