import MonitorModel

public enum CPUTicks {
    /// Usage fractions between two host tick samples. `nice` counts as user (like `top`).
    /// nil when the core lists differ in length, are empty, or any counter went backwards (reset → rebaseline).
    public static func usage(previous: [CoreTicks], current: [CoreTicks])
        -> (perCore: [Double], user: Double, system: Double, idle: Double)? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0
        for (p, c) in zip(previous, current) {
            guard let du = diff(c.user, p.user), let ds = diff(c.system, p.system),
                  let di = diff(c.idle, p.idle), let dn = diff(c.nice, p.nice) else { return nil }
            let busy = du + ds + dn
            let total = busy + di
            perCore.append(total == 0 ? 0 : Double(busy) / Double(total))
            user += du + dn
            system += ds
            idle += di
        }
        let total = Double(user + system + idle)
        guard total > 0 else { return (perCore, 0, 0, 0) }
        return (perCore, Double(user) / total, Double(system) / total, Double(idle) / total)
    }

    /// Guarded counter difference; nil when the counter went backwards.
    @inline(__always)
    private static func diff(_ cur: UInt64, _ prev: UInt64) -> UInt64? {
        cur >= prev ? cur - prev : nil
    }
}
