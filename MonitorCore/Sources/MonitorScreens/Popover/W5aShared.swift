import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

// Model/format helpers shared by the W5a screens (popover + Overview/CPU/GPU/Memory/Network pages).
// Page layout building blocks live in Pages/W5aPageSupport.swift.

extension MonitorModel.Category {
    /// Status-glyph arc of the category (stress coloring), nil for Power/Disk.
    var iconArc: IconArc? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .thermals: .thermals
        case .power, .disk: nil
        }
    }

    /// Headline system metric (its sensors decide the "—" tooltip).
    var headlineMetric: HistoryMetric {
        switch self {
        case .cpu: .cpuUsage
        case .gpu: .gpuUsage
        case .memory: .memUsed
        case .network: .netRx
        case .thermals: .socTemp
        case .power: .packageWatts
        case .disk: .diskRead
        }
    }

    var dashboardPage: DashboardPage {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .thermals: .thermals
        case .power: .power
        case .disk: .disk
        }
    }
}

extension AppSample {
    /// Row-action target for an app group.
    var target: ProcessTarget { .app(identity, pids: processIDs.map(\.pid)) }
    var name: String { identity.displayName.isEmpty ? identity.key.id : identity.displayName }
}

extension ProcessSample {
    var target: ProcessTarget { .process(pid: pid, name: name, path: path, uid: uid) }
}

extension ThermalPressure {
    /// "Nominal" / "Fair" / "Serious" / "Critical".
    var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}

extension MemoryPressureLevel {
    /// "Normal" / "Warning" / "Critical".
    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// DESIGN §3.7: Normal `textTertiary`, Warning `statusElevated`, Critical `statusCritical`.
    var color: Color {
        switch self {
        case .normal: TTColor.textTertiary
        case .warning: TTColor.statusElevated
        case .critical: TTColor.statusCritical
        }
    }

    /// Area color in the Memory pressure chart.
    var chartColor: Color {
        switch self {
        case .normal: TTColor.mem
        case .warning: TTColor.statusElevated
        case .critical: TTColor.statusCritical
        }
    }
}

enum W5a {
    /// Nice auto ceiling of a series (DESIGN §5.10) in the series' own unit, with a unit minimum.
    static func autoDomain(_ points: [SeriesPoint], minimum: Double, unit: Double = 1) -> ClosedRange<Double> {
        let m = points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 0
        return 0...(TTFormat.niceCeiling(m / unit, minimum: minimum) * unit)
    }

    /// Nice rate ceiling (bytes/s, ≥ 1 MB/s).
    static func rateDomain(_ points: [SeriesPoint]) -> ClosedRange<Double> {
        let m = points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 0
        return 0...TTFormat.niceRateCeiling(m)
    }

    /// Mean fan speed, nil without fans.
    static func averageFanRPM(_ fans: [FanSnapshot]) -> Double? {
        guard !fans.isEmpty else { return nil }
        return fans.map(\.rpm).reduce(0, +) / Double(fans.count)
    }

    /// Battery phrase for the popover / Overview (DESIGN §5.8): "82% · 5 h 40 m left"; no battery → "AC power".
    static func batteryPhrase(_ b: BatterySnapshot?) -> String? {
        guard let b, let pct = b.percent else { return b == nil ? "AC power" : nil }
        let p = TTFormat.percent(pct / 100)
        if b.isCharging { return "\(p) · charging" }
        if b.onAC { return "\(p) · AC power" }
        guard let t = b.timeRemaining else { return p }
        return "\(p) · \(TTFormat.duration(t)) left"
    }
}

extension View {
    /// Last element of a stretchable card: takes the card's extra height below itself (no extra stack gap, unlike a
    /// trailing `Spacer` in the card's VStack).
    func fillBelow() -> some View {
        frame(maxHeight: .infinity, alignment: .top)
    }

    /// The artboards' CSS line box (line-height 1.2 × font size): SwiftUI's natural SF line is ~1 pt taller at
    /// 11–13 pt, which adds up in stacked text blocks.
    func cssLine(_ fontSize: CGFloat) -> some View {
        frame(height: fontSize * 1.2)
    }
}
