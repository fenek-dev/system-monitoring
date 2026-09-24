import Darwin

/// Mach absolute-time ticks → ns. On Apple Silicon ticks are 125/3 ns (24 MHz), not 1:1 (findings/procs.md).
struct MachTimebase: Sendable, Equatable {
    let numer: UInt32
    let denom: UInt32

    init(numer: UInt32, denom: UInt32) {
        // A zero field would divide by zero; treat as 1:1.
        if numer == 0 || denom == 0 {
            self.numer = 1
            self.denom = 1
        } else {
            self.numer = numer
            self.denom = denom
        }
    }

    static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS else { return MachTimebase(numer: 1, denom: 1) }
        return MachTimebase(numer: info.numer, denom: info.denom)
    }()

    /// `ticks × numer / denom` in 128-bit; saturates at `UInt64.max` instead of trapping.
    func nanoseconds(_ ticks: UInt64) -> UInt64 {
        if numer == denom { return ticks }
        let wide = ticks.multipliedFullWidth(by: UInt64(numer))
        let d = UInt64(denom)
        guard wide.high < d else { return .max }
        return d.dividingFullWidth(wide).quotient
    }
}

/// Monotonic capture time (ARCHITECTURE §5 units: `CLOCK_UPTIME_RAW` ns).
@inline(__always)
func w6aUptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Guarded counter delta: nil when the counter went backwards (reset, pid reuse, recreated source).
@inline(__always)
func w6aCounterDelta(_ new: UInt64, _ old: UInt64) -> UInt64? { new >= old ? new - old : nil }
