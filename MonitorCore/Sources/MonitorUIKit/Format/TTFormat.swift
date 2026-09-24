import Foundation
import MonitorModel
import os

/// DESIGN §5 number formatting. Pure functions; nil / NaN / impossible negatives → "—".
/// Rounding is half-to-even; minus is U+2212; never "-0". Grouping follows `TTFormat.locale`.
public enum TTFormat {
    public static let unavailable = "—"
    static let minus = "\u{2212}"

    private static let localeBox = OSAllocatedUnfairLock(initialState: Locale.current)

    /// Locale for grouping separators (default `Locale.current`; snapshots and tests set en_US).
    public static var locale: Locale {
        get { localeBox.withLock { $0 } }
        set { localeBox.withLock { $0 = newValue } }
    }

    // MARK: - Core number formatting

    /// Half-to-even rounding at `digits` decimals.
    static func round(_ v: Double, _ digits: Int) -> Double {
        let p = pow(10, Double(digits))
        return (v * p).rounded(.toNearestOrEven) / p
    }

    /// Fixed-decimals, grouped number with U+2212 and no "-0".
    public static func number(_ v: Double, digits: Int = 0, grouping: Bool = true) -> String {
        var r = round(v, digits)
        if r == 0 { r = 0 } // drops the sign of -0
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(digits))
            .rounded(rule: .toNearestOrEven)
            .grouping(grouping ? .automatic : .never)
            .locale(locale)
        let s = abs(r).formatted(style)
        return r < 0 ? minus + s : s
    }

    private static func valid(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    private static func nonNegative(_ v: Double?) -> Double? {
        guard let v = valid(v), v >= 0 else { return nil }
        return v
    }

    // MARK: - §5.2 Percent

    /// `fraction` 0…1 → "34%" (system headline: integer by default).
    public static func percent(_ fraction: Double?, digits: Int = 0) -> String {
        guard let f = nonNegative(fraction) else { return unavailable }
        return number(f * 100, digits: digits) + "%"
    }

    /// A value already in percent → "22.1%".
    public static func percentValue(_ p: Double?, digits: Int = 1) -> String {
        guard let p = nonNegative(p) else { return unavailable }
        return number(p, digits: digits) + "%"
    }

    /// Per-app CPU/GPU (% of one core; may exceed 100), 1 decimal: "212.4%". `sign: false` for "% CPU" headers.
    public static func cpuPercent(_ p: Double?) -> String { cpuPercent(p, sign: true) }

    public static func cpuPercent(_ p: Double?, sign: Bool) -> String {
        guard let p = nonNegative(p) else { return unavailable }
        return number(p, digits: 1) + (sign ? "%" : "")
    }

    /// Integer per-app percent (Top consumer detail line): "212%".
    public static func cpuPercentInteger(_ p: Double?) -> String {
        guard let p = nonNegative(p) else { return unavailable }
        return number(p, digits: 0) + "%"
    }

    // MARK: - §5.3 Bytes

    public enum MemoryStyle: Sendable {
        /// Popover, tiles, stat strips, sidebar: GB with 1 decimal.
        case headline
        /// Tables, inspector: GB with 2 decimals.
        case detail
        /// Swap: always GB with 2 decimals.
        case swap
        /// RAM total: integer GB.
        case total
        /// Composition header: 1-decimal GB.
        case totalPrecise
    }

    public enum StorageStyle: Sendable {
        case headline, detail
        /// Capacities: integer GB below 1 TB, TB with trailing zeros trimmed above.
        case capacity
        /// Lifetime SSD totals: 1-decimal TB.
        case lifetime
    }

    /// Memory, detail style (binary units, labelled GB/MB): "3.82 GB", "894 MB".
    public static func bytes(_ b: UInt64?) -> String { memory(b, style: .detail) }

    public static func memory(_ b: UInt64?, style: MemoryStyle) -> String {
        guard let b else { return unavailable }
        let v = Double(b)
        switch style {
        case .headline: return scaled(v, base: 1024, gbDigits: 1, tbDigits: 2)
        case .detail: return scaled(v, base: 1024, gbDigits: 2, tbDigits: 2)
        case .swap: return number(v / pow(1024, 3), digits: 2) + " GB"
        case .total: return number(v / pow(1024, 3), digits: 0) + " GB"
        case .totalPrecise: return number(v / pow(1024, 3), digits: 1) + " GB"
        }
    }

    /// Storage and network totals (decimal units).
    public static func storage(_ b: UInt64?, style: StorageStyle) -> String {
        guard let b else { return unavailable }
        let v = Double(b)
        switch style {
        case .headline: return scaled(v, base: 1000, gbDigits: 1, tbDigits: 2)
        case .detail: return scaled(v, base: 1000, gbDigits: 2, tbDigits: 2)
        case .lifetime: return number(v / 1e12, digits: 1) + " TB"
        case .capacity:
            let gb = round(v / 1e9, 0)
            if gb < 1000 { return number(gb, digits: 0) + " GB" }
            var s = number(v / 1e12, digits: 2)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s + " TB"
        }
    }

    /// KB/MB integer, GB/TB with decimals; a value that rounds up to the next unit is promoted.
    private static func scaled(_ v: Double, base: Double, gbDigits: Int, tbDigits: Int) -> String {
        let units: [(String, Int)] = [("KB", 0), ("MB", 0), ("GB", gbDigits), ("TB", tbDigits)]
        var i = 0
        var x = v / base
        while i < units.count - 1, round(x, units[i].1) >= base {
            x /= base
            i += 1
        }
        return number(x, digits: units[i].1) + " " + units[i].0
    }

    // MARK: - §5.4 Rates

    public enum Direction: Sendable { case down, up }

    /// Headline rate: 0 → "0 KB/s"; Bits/s setting applies (network only).
    public static func rate(_ bps: Double?, units: UnitPreferences) -> String {
        rateParts(bps, bits: units.networkRate == .bits).map { $0.0 + " " + $0.1 } ?? unavailable
    }

    /// Headline rate with a direction prefix: "↓ 12.4 MB/s".
    public static func rate(_ bps: Double?, units: UnitPreferences, direction: Direction) -> String {
        let s = rate(bps, units: units)
        guard s != unavailable else { return s }
        return (direction == .down ? "↓ " : "↑ ") + s
    }

    /// Table cell: 0 → "—" (idle), else as headline.
    public static func rateCell(_ bps: Double?, units: UnitPreferences) -> String {
        guard let v = nonNegative(bps), v > 0 else { return unavailable }
        return rate(v, units: units)
    }

    /// Disk rates (always bytes).
    public static func diskRate(_ bps: Double?) -> String { rate(bps, units: UnitPreferences()) }

    /// Disk table cell: 0 → "—".
    public static func diskRateCell(_ bps: Double?) -> String { rateCell(bps, units: UnitPreferences()) }

    /// "R 142 · W 38.0 MB/s": the unit appears once when both share it.
    public static func ratePair(read: Double?, write: Double?) -> String {
        guard let r = rateParts(read, bits: false), let w = rateParts(write, bits: false) else {
            return "R \(diskRate(read)) · W \(diskRate(write))"
        }
        if r.1 == w.1 { return "R \(r.0) · W \(w.0) \(w.1)" }
        return "R \(r.0) \(r.1) · W \(w.0) \(w.1)"
    }

    /// Link rate: integer Mbps, grouped.
    public static func linkRate(_ mbps: Double?) -> String {
        guard let v = nonNegative(mbps) else { return unavailable }
        return number(v, digits: 0) + " Mbps"
    }

    /// (number, unit) for a rate; nil when unavailable.
    static func rateParts(_ bps: Double?, bits: Bool) -> (String, String)? {
        guard let raw = nonNegative(bps) else { return nil }
        let v = bits ? raw * 8 : raw
        let u = bits ? ["Kbps", "Mbps", "Gbps"] : ["KB/s", "MB/s", "GB/s"]
        if v == 0 { return ("0", u[0]) }
        if v < 1000 { return ("<1", u[0]) }
        let kb = v / 1e3
        if round(kb, 0) < 1000 { return (number(kb, digits: 0), u[0]) }
        let mb = v / 1e6
        if round(mb, 1) < 100 { return (number(mb, digits: 1), u[1]) }
        if round(mb, 0) < 1000 { return (number(mb, digits: 0), u[1]) }
        return (number(v / 1e9, digits: 2), u[2])
    }

    /// IOPS: < 1000 integer; ≥ 1000 "3.4k".
    public static func iops(_ v: Double?) -> String {
        guard let v = nonNegative(v) else { return unavailable }
        if round(v, 0) < 1000 { return number(v, digits: 0) }
        return number(v / 1000, digits: 1) + "k"
    }

    /// Pages/s, swaps/s: "0 / s".
    public static func perSecond(_ v: Double?) -> String {
        guard let v = nonNegative(v) else { return unavailable }
        return number(v, digits: 0) + " / s"
    }

    // MARK: - §5.5 Temperature

    private static func converted(_ c: Double, _ units: UnitPreferences) -> Double {
        units.temperature == .fahrenheit ? c * 9 / 5 + 32 : c
    }

    /// "62°C" / "144°F".
    public static func temperature(_ c: Double?, units: UnitPreferences) -> String {
        guard let c = valid(c) else { return unavailable }
        return number(converted(c, units), digits: 0) + (units.temperature == .fahrenheit ? "°F" : "°C")
    }

    /// Compact (sidebar, axes): "62°".
    public static func temperatureCompact(_ c: Double?, units: UnitPreferences) -> String {
        guard let c = valid(c) else { return unavailable }
        return number(converted(c, units), digits: 0) + "°"
    }

    // MARK: - §5.6 Power

    /// System power: 1 decimal W ("18.6 W", "−18.9 W").
    public static func watts(_ w: Double?, digits: Int = 1) -> String {
        guard let w = valid(w) else { return unavailable }
        return number(w, digits: digits) + " W"
    }

    /// Per-app average power: ≥ 10 W 1 decimal; 0.01–9.99 W 2 decimals; (0, 0.01) "<0.01 W"; 0 → "—".
    public static func appWatts(_ w: Double?) -> String {
        guard let w = nonNegative(w), w > 0 else { return unavailable }
        if w < 0.01 && round(w, 2) < 0.01 { return "<0.01 W" }
        if round(w, 2) >= 10 { return number(w, digits: 1) + " W" }
        return number(w, digits: 2) + " W"
    }

    /// Battery capacity: "68.1 of 72.4 Wh".
    public static func wattHours(_ current: Double?, of full: Double?) -> String {
        guard let c = nonNegative(current), let f = nonNegative(full) else { return unavailable }
        return "\(number(c, digits: 1)) of \(number(f, digits: 1)) Wh"
    }

    // MARK: - §5.7 Frequency, rpm, misc

    /// GPU frequency: integer MHz, grouped ("1,180 MHz").
    public static func frequency(_ mhz: Double?) -> String {
        guard let v = nonNegative(mhz) else { return unavailable }
        return number(v, digits: 0) + " MHz"
    }

    /// CPU cluster frequency in GHz ("4.12 GHz"; popover sub-line uses 1 decimal).
    public static func ghz(_ mhz: Double?, digits: Int = 2) -> String {
        guard let v = nonNegative(mhz) else { return unavailable }
        return number(v / 1000, digits: digits) + " GHz"
    }

    public static func rpm(_ r: Double?) -> String {
        guard let v = nonNegative(r) else { return unavailable }
        return number(v, digits: 0) + " rpm"
    }

    /// "max 5,700".
    public static func maxRPM(_ r: Double?) -> String {
        guard let v = nonNegative(r) else { return unavailable }
        return "max " + number(v, digits: 0)
    }

    public static func count(_ n: Int?) -> String {
        guard let n, n >= 0 else { return unavailable }
        return number(Double(n), digits: 0)
    }

    /// "2.41 · 2.10 · 1.98".
    public static func loadAverage(_ values: [Double]?) -> String {
        guard let values, !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return unavailable }
        return values.map { number($0, digits: 2) }.joined(separator: " · ")
    }

    /// "18 ms"; below 1 ms "<1 ms".
    public static func latency(_ ms: Double?) -> String {
        guard let v = nonNegative(ms) else { return unavailable }
        if v < 1 { return "<1 ms" }
        return number(v, digits: 0) + " ms"
    }

    /// "−52 dBm".
    public static func dBm(_ v: Double?) -> String {
        guard let v = valid(v) else { return unavailable }
        return number(v, digits: 0) + " dBm"
    }

    /// "2.3 : 1".
    public static func compressionRatio(_ r: Double?) -> String {
        guard let v = nonNegative(r) else { return unavailable }
        return number(v, digits: 1) + " : 1"
    }

    // MARK: - §5.8 Durations

    /// Two largest units from d/h/m ("5 h 40 m", "4 d 7 h", "12 m"); under 1 min "<1 m".
    public static func duration(_ d: Duration?) -> String {
        guard let d else { return unavailable }
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        guard seconds.isFinite, seconds >= 0 else { return unavailable }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 1 { return "<1 m" }
        let days = totalMinutes / 1440, hours = (totalMinutes % 1440) / 60, minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) m" : "\(hours) h" }
        return "\(minutes) m"
    }

    /// Cumulative CPU/GPU time: "m:ss" under 1 h, "h:mm:ss" from 1 h.
    public static func cpuTime(_ ns: UInt64?) -> String {
        guard let ns else { return unavailable }
        let total = Int(ns / 1_000_000_000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
    }

    /// 24-hour "HH:mm" in `timeZone`.
    public static func clock(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return unavailable }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        return (h < 10 ? "0\(h)" : "\(h)") + ":" + (m < 10 ? "0\(m)" : "\(m)")
    }

    // MARK: - §5.10 Chart domains

    /// Smallest "nice" ceiling ≥ `v` from {1, 2, 4, 5} × 10^k, at least `minimum`.
    public static func niceCeiling(_ v: Double, minimum: Double = 1) -> Double {
        let target = max(v.isFinite ? v : 0, minimum)
        var decade = pow(10, floor(log10(target)))
        while true {
            for m in [1.0, 2, 4, 5] where m * decade >= target * (1 - 1e-12) {
                return m * decade
            }
            decade *= 10
        }
    }

    /// Nice rate ceiling in bytes/s, computed in MB/s with a 1 MB/s minimum.
    public static func niceRateCeiling(_ bps: Double) -> Double {
        niceCeiling(bps / 1e6, minimum: 1) * 1e6
    }

    /// Legend scale label for a nice ceiling: "40 MB/s", "2 GB/s" (integer in its unit).
    public static func rateScale(_ bps: Double, units: UnitPreferences) -> String {
        let bits = units.networkRate == .bits
        let v = bits ? bps * 8 : bps
        let u = bits ? ["Kbps", "Mbps", "Gbps"] : ["KB/s", "MB/s", "GB/s"]
        if v >= 1e9 { return number(v / 1e9, digits: v / 1e9 == floor(v / 1e9) ? 0 : 1) + " " + u[2] }
        if v >= 1e6 { return number(v / 1e6, digits: 0) + " " + u[1] }
        return number(v / 1e3, digits: 0) + " " + u[0]
    }
}
