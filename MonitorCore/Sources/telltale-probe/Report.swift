import Foundation
import MonitorModel

/// Frame summaries for `--frames` / `--record` (compare with `top -o cpu`, `ps`, `vm_stat`).
enum Report {
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func frac(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    static func mb(_ v: UInt64?) -> String { v.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "—" }
    static func gb(_ v: UInt64?) -> String { v.map { String(format: "%.2f GB", Double($0) / 1_073_741_824) } ?? "—" }
    static func w(_ v: Double?) -> String { v.map { String(format: "%.2f W", $0) } ?? "—" }
    static func rate(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 1_048_576 ? String(format: "%.1f MB/s", v / 1_048_576) : String(format: "%.1f KB/s", v / 1024)
    }
    static func c(_ v: Double?) -> String { v.map { String(format: "%.1f°C", $0) } ?? "—" }

    static func appCPUSum(_ f: SystemFrame) -> Double { f.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) } }

    static func oneLine(_ f: SystemFrame) -> String {
        let top = f.apps.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
        return "cpu \(frac(f.cpu.usage)) Σapps \(String(format: "%.0f%%", appCPUSum(f))) mem \(gb(f.memory.used)) "
            + "procs \(f.processes.count) apps \(f.apps.count) top \(top?.identity.displayName ?? "—") \(pct(top?.cpuPercent))"
            + (f.interval == nil ? " (no rates)" : "")
    }

    static func frame(_ f: SystemFrame, verbose: Bool) -> String {
        var out: [String] = []
        let cores = f.cpu.cores.count > 0 ? f.cpu.cores.count : f.device.performanceCores + f.device.efficiencyCores
        let sum = appCPUSum(f)
        let sysPct = f.cpu.usage.map { $0 * 100 * Double(max(cores, 1)) }
        out.append("interval \(f.interval.map { "\($0)" } ?? "— (first frame, no rates)") mode \(f.mode) alert \(f.alert.level)")
        out.append("cpu \(frac(f.cpu.usage)) (user \(frac(f.cpu.user)) sys \(frac(f.cpu.system))) = \(pct(sysPct)) of \(cores) cores; "
            + "Σ app cpu \(pct(sum))\(sysPct.map { $0 > 0 ? String(format: " (%.0f%% of system)", sum / $0 * 100) : "" } ?? "")")
        out.append("load \(f.cpu.loadAverage.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " ") } ?? "—") "
            + "procs \(f.cpu.processCount.map(String.init) ?? "—") threads \(f.cpu.threadCount.map(String.init) ?? "—")")
        out.append("memory used \(gb(f.memory.used)) / \(gb(f.memory.total)) app \(gb(f.memory.appMemory)) wired \(gb(f.memory.wired)) "
            + "compressed \(gb(f.memory.compressed)) swap \(gb(f.memory.swapUsed)) pressure \(f.memory.pressureLevel.map { "\($0)" } ?? "—")")
        out.append("gpu \(frac(f.gpu.usage)) \(f.gpu.frequencyMHz.map { String(format: "%.0f MHz", $0) } ?? "—"); "
            + "power pkg \(w(f.power.packageWatts)) cpu \(w(f.power.cpuWatts)) gpu \(w(f.power.gpuWatts)) system \(w(f.power.systemWatts))")
        out.append("thermal \(f.thermals.pressure.map { "\($0)" } ?? "—") soc \(c(f.thermals.socAverage)) "
            + "fans \(f.thermals.fans.map { String(format: "%.0f", $0.rpm) }.joined(separator: "/")) approx \(f.thermals.approximateMapping)")
        out.append("net rx \(rate(f.network.rxBps)) tx \(rate(f.network.txBps)); disk r \(rate(f.disk.readBps)) w \(rate(f.disk.writeBps))")

        let restricted = f.processes.filter { $0.provenance == .restricted }.count
        let coalition = f.processes.filter { $0.provenance == .coalition }.count
        out.append("processes \(f.processes.count) (restricted \(restricted), coalition-filled \(coalition)); apps \(f.apps.count)")
        let top = f.apps.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }.prefix(verbose ? 8 : 5)
        out.append("  app                                cpu      mem       gpu     energy   procs")
        for a in top {
            out.append("  " + pad(String(a.identity.displayName.prefix(34)), 34) + " " + pad(pct(a.cpuPercent), 8) + " "
                + pad(mb(a.memory), 9) + " " + pad(pct(a.gpuPercent), 7) + " " + pad(w(a.energyWatts) + (a.energyEstimated ? "~" : ""), 8)
                + " \(a.processIDs.count)\(a.hiddenProcessCount > 0 ? "+\(a.hiddenProcessCount)" : "")")
        }
        if verbose {
            let rootTop = f.processes.filter { $0.uid == 0 }.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }.prefix(5)
            out.append("  root processes by cpu: " + rootTop.map { "\($0.name) \(pct($0.cpuPercent)) [\($0.provenance)]" }
                .joined(separator: ", "))
        }
        let bad = f.sensorHealth.filter { $0.value != .ok }.sorted { $0.key.rawValue < $1.key.rawValue }
        if !bad.isEmpty {
            out.append("sensor health: " + bad.map { "\($0.key.rawValue)=\($0.value.reason ?? "?")" }.joined(separator: "; "))
        }
        if !f.events.isEmpty { out.append("events: " + f.events.map { "\($0.kind)" }.joined(separator: ", ")) }
        return out.joined(separator: "\n")
    }
}
