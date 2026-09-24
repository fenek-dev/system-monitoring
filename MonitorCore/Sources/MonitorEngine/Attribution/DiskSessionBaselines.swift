import Darwin
import Foundation
import MonitorModel

/// Session start (ruling): Telltale's own process start — `p_starttime` of `getpid()`, µs since epoch, read once.
/// Session totals (CPU, network, disk; per process and per app) count usage from this instant: a process started at or
/// after it counts in full, an older one from its first sample. `FrameAssembler(sessionStartUs:)` overrides it (tests,
/// replays). Falls back to "now" if the sysctl fails.
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
/// `Result.delta*` = growth of the session value since the previous call (the app session sums these, ruling).
struct DiskSessionBaselines: Sendable {
    private struct Counter: Sendable {
        var base: UInt64
        var carried: UInt64 = 0          // counted before the last rebase
        var last: UInt64
        var lastSession: UInt64 = 0

        /// (session value, growth since the previous call)
        mutating func update(_ counter: UInt64) -> (UInt64, UInt64) {
            if counter < last {                              // went backwards: rebase, keep what was counted
                carried = ProcessAssembler.saturatingAdd(carried, last - base)
                base = counter
            }
            last = counter
            let session = ProcessAssembler.saturatingAdd(carried, counter - base)
            let growth = session >= lastSession ? session - lastSession : 0
            lastSession = session
            return (session, growth)
        }
    }
    private struct Baseline: Sendable { var read: Counter?, write: Counter? }

    struct Result: Equatable {
        var read: UInt64?, write: UInt64?
        var deltaRead: UInt64 = 0, deltaWrite: UInt64 = 0
        /// A disk counter was seen for this process for the first time (the app now has disk data).
        var firstSight = false
    }

    let sessionStartUs: UInt64
    private var baselines: [ProcessID: Baseline] = [:]

    init(sessionStartUs: UInt64) {
        self.sessionStartUs = sessionStartUs
    }

    /// Session bytes for `p`'s counters (nil where the counter is nil) and their growth since the last call.
    mutating func session(_ p: RawProcess) -> Result {
        let newborn = p.id.startTimeUs >= sessionStartUs
        var b = baselines[p.id] ?? Baseline()
        var out = Result()
        func value(_ counter: UInt64?, _ c: inout Counter?) -> (UInt64, UInt64)? {
            guard let counter else { return nil }
            if c == nil {
                c = Counter(base: newborn ? 0 : counter, last: counter)
                out.firstSight = true
            }
            return c!.update(counter)
        }
        if let (s, d) = value(p.diskReadBytes, &b.read) { out.read = s; out.deltaRead = d }
        if let (s, d) = value(p.diskWriteBytes, &b.write) { out.write = s; out.deltaWrite = d }
        baselines[p.id] = b
        return out
    }

    mutating func prune(keeping live: Set<ProcessID>) {
        for id in baselines.keys.filter({ !live.contains($0) }) { baselines[id] = nil }
    }

    var count: Int { baselines.count }
}
