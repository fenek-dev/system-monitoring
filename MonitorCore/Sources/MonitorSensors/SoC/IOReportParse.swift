import Foundation
import MonitorModel

/// One channel of an `IOReportCreateSamplesDelta` result, copied out of CF (pure value; fixture format).
struct IOReportChannelSample: Codable, Sendable, Equatable {
    var group: String
    var subgroup: String
    var name: String
    var unit: String?
    /// Simple (format 1) channels: accumulated value over the interval.
    var value: Int64?
    /// State (format 2) channels: residency per state, in IOReport order.
    var states: [State]?

    struct State: Codable, Sendable, Equatable {
        var name: String
        var residency: Int64
    }
}

/// Pure decoding of IOReport deltas → `SoCPowerReading` (docs/findings/ioreport.md).
enum IOReportParse {
    static let energyGroup = "Energy Model"
    static let cpuStatsGroup = "CPU Stats"
    static let clusterSubgroup = "CPU Complex Performance States"
    static let gpuStatsGroup = "GPU Stats"
    static let gpuSubgroup = "GPU Performance States"
    static let socStatsGroup = "SoC Stats"
    static let clusterPowerSubgroup = "Cluster Power States"
    /// Idle state names seen: `OFF` (GPUPH), `IDLE` (ECPU/PCPU on macOS 26.5), `INACT` (SoC cluster power
    /// states); `DOWN` kept as a safe superset.
    static let idleStates: Set<String> = ["IDLE", "OFF", "DOWN", "INACT"]
    /// SoC Stats / Cluster Power States channels that are media engines. M1 Max exposes one combined
    /// AVE (encoder) + MSR (scaler) power domain; it lights up for H.264 encode and for decode (MSR scaling).
    /// No VDEC (AVD) or ProRes residency channel exists (docs/findings/temps.md "Production verification (W6b)").
    static let mediaChannels: [String: String] = ["AVEMSR": "Video encoder/scaler"]

    /// Energy unit → divisor to joules. Unknown unit → nil (value not trusted).
    static func joules(_ raw: Int64, unit: String?) -> Double? {
        let divisor: Double
        switch unit?.trimmingCharacters(in: .whitespaces) {
        case "mJ": divisor = 1e3
        case "uJ", "µJ": divisor = 1e6
        case "nJ": divisor = 1e9
        default: return nil
        }
        return Double(raw) / divisor
    }

    /// Cluster residency channel name → kind. `*CPM*` channels (voltage-state trackers) are excluded.
    static func clusterKind(_ name: String) -> ClusterKind? {
        guard !name.contains("CPM") else { return nil }
        if name.hasPrefix("ECPU") { return .efficiency }
        if name.hasPrefix("PCPU") { return .performance }
        return nil
    }

    /// Energy channels for a cluster: "ECPU" → EACC_CPU / EACC0_CPU; "PCPU1" → PACC1_CPU; "PCPU" → PACC0_CPU / PACC_CPU.
    static func clusterEnergyNames(_ cluster: String) -> [String] {
        let letter = cluster.hasPrefix("E") ? "E" : "P"
        let index = Int(cluster.drop { !$0.isNumber }) ?? 0
        return index == 0 ? ["\(letter)ACC_CPU", "\(letter)ACC0_CPU"] : ["\(letter)ACC\(index)_CPU"]
    }

    /// Active fraction + weighted active MHz of a state channel. Active state i ↔ `table[i]` (ascending).
    /// MHz is nil when the table doesn't fit: fewer active states than table entries, or residency in a
    /// state past the table's end (GPUPH has P1…P15 but only P1…P6 carry residency on M1 Max).
    static func residency(_ states: [IOReportChannelSample.State], table: [Double]?) -> (active: Double, mhz: Double?)? {
        var total: Double = 0, idle: Double = 0
        var activeStates: [Double] = []
        for s in states {
            let r = Double(max(0, s.residency))
            total += r
            if idleStates.contains(s.name) { idle += r } else { activeStates.append(r) }
        }
        guard total > 0 else { return nil }
        let active = min(1, max(0, (total - idle) / total))
        var mhz: Double?
        if let table, !table.isEmpty, activeStates.count >= table.count,
           activeStates[table.count...].allSatisfy({ $0 == 0 }) {
            let busy = activeStates.reduce(0, +)
            if busy > 0 { mhz = zip(activeStates, table).reduce(0) { $0 + $1.0 * $1.1 } / busy }
        }
        return (active, mhz)
    }

    static func reading(channels: [IOReportChannelSample], interval: Duration, pstates: PStateTables?) -> SoCPowerReading {
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        var energy: [String: Double] = [:]     // channel name → watts
        for ch in channels where ch.group == energyGroup {
            guard seconds > 0, let v = ch.value, let j = joules(v, unit: ch.unit) else { continue }
            energy[ch.name] = max(0, j / seconds)
        }
        func sum(_ prefix: String) -> Double? {
            let hits = energy.filter { $0.key.hasPrefix(prefix) && $0.key.dropFirst(prefix.count).allSatisfy(\.isNumber) }
            return hits.isEmpty ? nil : hits.values.reduce(0, +)
        }

        var r = SoCPowerReading(interval: interval)
        r.cpuWatts = energy["CPU Energy"]
        r.gpuWatts = energy["GPU Energy"] ?? energy["GPU0"]
        r.aneWatts = sum("ANE")
        r.dramWatts = sum("DRAM")

        for ch in channels where ch.group == cpuStatsGroup && ch.subgroup == clusterSubgroup {
            guard let kind = clusterKind(ch.name), let states = ch.states else { continue }
            let table = kind == .efficiency ? pstates?.ecpuMHz : pstates?.pcpuMHz
            guard let res = residency(states, table: table) else { continue }
            let watts = clusterEnergyNames(ch.name).lazy.compactMap { energy[$0] }.first
            r.clusters.append(ClusterResidency(
                name: ch.name, kind: kind, activeFraction: res.active,
                frequencyMHz: res.mhz, maxFrequencyMHz: res.mhz == nil ? nil : table?.last, watts: watts))
        }
        r.clusters.sort { ($0.kind == .efficiency ? 0 : 1, $0.name) < ($1.kind == .efficiency ? 0 : 1, $1.name) }
        if r.cpuWatts == nil, !r.clusters.isEmpty, r.clusters.allSatisfy({ $0.watts != nil }) {
            r.cpuWatts = r.clusters.reduce(0) { $0 + ($1.watts ?? 0) }
        }

        if let gpu = channels.first(where: { $0.group == gpuStatsGroup && $0.subgroup == gpuSubgroup && $0.name == "GPUPH" }),
           let states = gpu.states, let res = residency(states, table: pstates?.gpuMHz) {
            r.gpuActiveFraction = res.active
            r.gpuFrequencyMHz = res.mhz
            r.gpuMaxFrequencyMHz = res.mhz == nil ? nil : pstates?.gpuMHz?.last
        }

        for ch in channels where ch.group == socStatsGroup && ch.subgroup == clusterPowerSubgroup {
            guard let label = mediaChannels[ch.name], let states = ch.states,
                  let res = residency(states, table: nil) else { continue }
            r.mediaEngines.append(MediaEngineReading(name: label, activeFraction: res.active))
        }
        return r
    }
}
