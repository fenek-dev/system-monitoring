import MonitorModel

public enum CPUTicks {
    /// Usage fractions between two host tick samples. `nice` counts as user (like `top`).
    /// nil when the core lists differ in length, are empty, or any counter went backwards (reset → rebaseline).
    public static func usage(previous: [CoreTicks], current: [CoreTicks])
        -> (perCore: [Double], user: Double, system: Double, idle: Double)? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        // Sums in Double: tick deltas are small, but garbage counters must not trap on overflow.
        var user = 0.0, system = 0.0, idle = 0.0
        for (p, c) in zip(previous, current) {
            guard let du = diff(c.user, p.user), let ds = diff(c.system, p.system),
                  let di = diff(c.idle, p.idle), let dn = diff(c.nice, p.nice) else { return nil }
            let busy = Double(du) + Double(ds) + Double(dn)
            let total = busy + Double(di)
            perCore.append(total == 0 ? 0 : busy / total)
            user += Double(du) + Double(dn)
            system += Double(ds)
            idle += Double(di)
        }
        let total = user + system + idle
        guard total > 0 else { return (perCore, 0, 0, 0) }
        return (perCore, user / total, system / total, idle / total)
    }

    /// Guarded counter difference; nil when the counter went backwards.
    @inline(__always)
    private static func diff(_ cur: UInt64, _ prev: UInt64) -> UInt64? {
        cur >= prev ? cur - prev : nil
    }
}
