import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Sidebar device footer (DESIGN §3.0 item 4): 1-pt top `separator`, padding 12/10/4, VStack gap 3.
///   "MacBook Pro 14″"
///   "M4 Pro · 8P + 4E CPU · 16-core GPU"
///   "24 GB unified memory · up 4 d 7 h"
public struct DeviceHeader: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.now) private var now

    public init() {}

    public var body: some View {
        let lines = Self.lines(live.device, now: now ?? live.lastUpdate ?? Date())
        VStack(alignment: .leading, spacing: 3) {
            Text(lines.model).font(ShellStyle.body12Strong).foregroundStyle(ShellStyle.textPrimary)
            Text(lines.chip).font(ShellStyle.caption).foregroundStyle(ShellStyle.textSecondary)
            Text(lines.memory).font(ShellStyle.caption).foregroundStyle(ShellStyle.textSecondary).monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12).padding(.horizontal, 10).padding(.bottom, 4)
        .overlay(alignment: .top) { ShellStyle.separator.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    /// Pure copy builder (unit-tested).
    public static func lines(_ d: DeviceInfo, now: Date) -> (model: String, chip: String, memory: String) {
        let chipShort = d.chipName.hasPrefix("Apple ") ? String(d.chipName.dropFirst(6)) : d.chipName
        var chip = [chipShort]
        if d.performanceCores + d.efficiencyCores > 0 {
            chip.append("\(d.performanceCores)P + \(d.efficiencyCores)E CPU")
        }
        if let g = d.gpuCores { chip.append("\(g)-core GPU") }
        var mem: [String] = []
        if d.memoryBytes > 0 { mem.append("\(d.memoryBytes / 1_073_741_824) GB unified memory") }
        if d.bootTime.timeIntervalSince1970 > 0, now > d.bootTime {
            mem.append("up " + uptime(now.timeIntervalSince(d.bootTime)))
        }
        return (ShellFormat.modelShortName(d.modelName), chip.joined(separator: " · "), mem.joined(separator: " · "))
    }

    /// DESIGN §5.8 coarse uptime: "4 d 7 h", "7 h 12 m", "12 m".
    static func uptime(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d) d \(h % 24) h" }
        if h > 0 { return "\(h) h \(m % 60) m" }
        return "\(m) m"
    }
}
