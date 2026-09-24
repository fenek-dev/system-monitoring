import Darwin
import MonitorModel

/// W6c process-identity helpers (sysctl `KERN_PROC_PID`), used by the NStat sensor to turn a pid into a `ProcessID`.
enum W6cProcess {
    /// kinfo_proc `p_starttime` in µs since the epoch; nil if the pid does not exist (or the call fails).
    static func startTimeUs(pid: Int32) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.size else {
            return nil
        }
        // A missing pid yields success with size 0 (handled above) or a zeroed struct.
        guard info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec >= 0, tv.tv_usec >= 0 else { return nil }
        return UInt64(tv.tv_sec) * 1_000_000 + UInt64(tv.tv_usec)
    }

    /// True when `p` is a running process: the pid exists and (if known) its start time matches.
    static func isAlive(_ p: ProcessID) -> Bool {
        guard p.pid >= 0, let st = startTimeUs(pid: p.pid) else { return false }
        return p.startTimeUs == 0 || p.startTimeUs == st
    }
}

enum W6cClock {
    /// Monotonic uptime in ns (ARCHITECTURE §5 convention).
    static func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
