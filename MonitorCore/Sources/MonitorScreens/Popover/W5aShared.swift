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

// MARK: - Page container

/// `PageScroll` whose content is stretched to the viewport when the viewport is at least `minContentHeight` tall,
/// so the flexible bottom card fills the window (DESIGN §3.0 height rule) and the page only scrolls below that.
/// Snapshots: `PageScroll` already fills its frame.
struct FlexPage<Content: View>: View {
    let minContentHeight: CGFloat
    let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    init(minContentHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.minContentHeight = minContentHeight
        self.content = content()
    }

    var body: some View {
        if isSnapshot {
            PageScroll { content }
        } else {
            GeometryReader { geo in
                let h = geo.size.height - 2 * TTSpace.pagePadding
                PageScroll {
                    VStack(alignment: .leading, spacing: TTSpace.gridGap) { content }
                        .frame(height: h >= minContentHeight ? h : nil, alignment: .top)
                }
            }
        }
    }
}

/// DESIGN §3.0 named grids (`grid3`, `grid5`, `6 × 1fr`): `columns` equal tracks with `spacing` gaps; subview i
/// spans `spans[i]` tracks (default 1). The row is as tall as its tallest cell (at least `minHeight`) and every cell
/// is proposed that height, so cards stretch (their flex child takes the extra).
struct GridRow: Layout {
    var columns: Int
    var spans: [Int] = []
    var spacing: CGFloat = TTSpace.gridGap
    var minHeight: CGFloat = 0

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let track = (total - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (0..<count).map { i in
            let s = CGFloat(i < spans.count ? spans[i] : 1)
            return track * s + spacing * (s - 1)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1020
        let ws = widths(width, count: subviews.count)
        let tallest = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: max(minHeight, tallest))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (sub, w) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            sub.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

extension HistoryRange {
    /// Card title that follows the range (DESIGN §3.0): "Last 60 seconds", "Last hour", …
    var lastTitle: String {
        switch self {
        case .live: "Last 60 seconds"
        case .hour: "Last hour"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }
}

/// Splits a formatted value into number and unit for display+unit typography: "15.1 GB" → ("15.1", "GB"),
/// "34%" → ("34", "%"), "62°C" → ("62", "°C"). "—" → (nil, nil).
func splitUnit(_ s: String) -> (value: String?, unit: String?) {
    guard s != TTFormat.unavailable else { return (nil, nil) }
    if let space = s.lastIndex(of: " ") { return (String(s[..<space]), String(s[s.index(after: space)...])) }
    if let i = s.firstIndex(where: { $0 == "%" || $0 == "°" }) { return (String(s[..<i]), String(s[i...])) }
    return (s, nil)
}

// MARK: - Small shared views

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

/// Hands `content` the number of whole table rows that fit the proposed height (header 26 + 4 top padding +
/// n × row). Used where a table shows "as many as fit" and in snapshots, so no row is cut in half.
struct FitRows<Content: View>: View {
    var rowHeight: CGFloat = 34
    var header: CGFloat = 26
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        GeometryReader { geo in
            content(max(1, Int((geo.size.height - header - 4) / rowHeight)))
        }
    }
}

/// Value legend spread space-between (Overview Power card, 298 wide): `TTLegend`'s fixed gap 14 does not fit four
/// "CPU 10.8 W" items; one line per item, scaled down slightly if needed (the artboard's CSS wraps "W" instead).
struct ColumnLegend: View {
    let items: [(label: String, color: Color)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { Spacer(minLength: 8) }
                HStack(spacing: TTSpace.x6) {
                    RoundedRectangle(cornerRadius: TTRadius.r2, style: .continuous).fill(items[i].color)
                        .frame(width: 8, height: 8)
                    Text(items[i].label).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }
}
