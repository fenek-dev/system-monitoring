import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

// Helpers shared by the W5a screens (popover + Overview/CPU/GPU/Memory/Network pages).
// Lives under Popover/ only because that is the directory W5a owns (plan §1).

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

// MARK: - Range-aware chart data

/// Chart data for the page's range (DESIGN §3.0 "Range behavior"): Live reads `LiveModel.series` (last 60 s),
/// other ranges read the store (`historyProvider.series(…, bucket: nil)` = the range's display bucket).
struct RangeSeries {
    var range: HistoryRange
    var end: Date
    var points: [HistoryMetric: [SeriesPoint]]

    subscript(_ m: HistoryMetric) -> [SeriesPoint] { points[m] ?? [] }
}

/// Reads `metrics` for `NavigationModel.range` and hands them to `content`. Store reads run in a `.task` keyed by
/// range and the display-bucket–rounded end, so a stored range reloads once per bucket, not per tick.
struct RangeSeriesReader<Content: View>: View {
    let metrics: [HistoryMetric]
    @ViewBuilder let content: (RangeSeries) -> Content

    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var now
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]

    init(_ metrics: [HistoryMetric], @ViewBuilder content: @escaping (RangeSeries) -> Content) {
        self.metrics = metrics
        self.content = content
    }

    private struct LoadKey: Equatable {
        var range: HistoryRange
        var bucketEnd: Date
    }

    var body: some View {
        let range = nav.range
        let end = now ?? live.lastUpdate ?? Date()
        if range == .live {
            content(RangeSeries(range: .live, end: end,
                                points: Dictionary(uniqueKeysWithValues: metrics.map { ($0, live.series($0)) })))
        } else {
            let bucket = Double(range.displayBucket.components.seconds)
            let bucketEnd = Date(timeIntervalSince1970: (end.timeIntervalSince1970 / bucket).rounded(.up) * bucket)
            content(RangeSeries(range: range, end: end, points: stored))
                .task(id: LoadKey(range: range, bucketEnd: bucketEnd)) {
                    let loaded = try? await history.series(metrics, range: range, end: end, bucket: nil)
                    stored = loaded ?? [:]
                }
        }
    }
}

// MARK: - Small shared views

extension View {
    /// The artboards' CSS line box (line-height 1.2 × font size): SwiftUI's natural SF line is ~1 pt taller at
    /// 11–13 pt, which adds up in stacked text blocks.
    func cssLine(_ fontSize: CGFloat) -> some View {
        frame(height: fontSize * 1.2)
    }
}

/// Card header trailing link.
struct PageLink: View {
    let title: String
    let page: DashboardPage
    @Environment(NavigationModel.self) private var nav

    init(_ title: String, to page: DashboardPage) {
        self.title = title
        self.page = page
    }

    var body: some View {
        TTLink(title) { nav.page = page }
    }
}

/// Table name cell for an app group.
struct AppNameCell: View {
    let app: AppSample
    var body: some View { TTNameCell(identity: app.identity, name: app.name) }
}

/// Right-aligned metric cell (`MetricValue`, table font inherited).
func metricCell(_ text: String?, reason: String? = nil, estimated: Bool = false, secondary: Bool = false) -> AnyView {
    AnyView(
        MetricValue(text, unavailableReason: reason, estimated: estimated, font: TTFont.body12)
            .foregroundStyle(secondary ? TTColor.textSecondary : TTColor.textPrimary)
    )
}

/// Table-card row cap: rows that fit in the flexible table area (header 26 + 4 top padding + n × 34).
func rowsThatFit(_ height: CGFloat, rowHeight: CGFloat = 34, header: CGFloat = 26) -> Int {
    max(1, Int((height - header - 4) / rowHeight))
}
