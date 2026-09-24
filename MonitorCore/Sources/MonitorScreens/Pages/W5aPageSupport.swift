import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

// Page building blocks shared by the W5a pages (Overview, CPU, GPU, Memory, Network).

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
/// range and the display-bucket–rounded end, so a stored range reloads once per bucket, not per tick. A range
/// switch clears the previous range's data at once (charts show "Collecting…" until the store answers).
struct RangeSeriesReader<Content: View>: View {
    let metrics: [HistoryMetric]
    @ViewBuilder let content: (RangeSeries) -> Content

    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var now
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]
    @State private var storedRange: HistoryRange?

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
            content(RangeSeries(range: range, end: end, points: storedRange == range ? stored : [:]))
                .task(id: LoadKey(range: range, bucketEnd: bucketEnd)) {
                    let loaded = try? await history.series(metrics, range: range, end: end, bucket: nil)
                    guard !Task.isCancelled else { return }
                    stored = loaded ?? [:]
                    storedRange = range
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

/// Value legend spread space-between (Overview Power card, 298 wide). `TTLegend`'s fixed gap 14 does not fit four
/// "CPU 10.8 W" items (the artboard's CSS wraps "W" onto a second line). One type size for every item: `caption`
/// when it fits, else all items in `micro`.
struct ColumnLegend: View {
    let items: [(label: String, color: Color)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(TTFont.caption, gap: 8)
            row(TTFont.micro, gap: 6)
        }
    }

    private func row(_ font: Font, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { Spacer(minLength: gap) }
                HStack(spacing: TTSpace.x6) {
                    RoundedRectangle(cornerRadius: TTRadius.r2, style: .continuous).fill(items[i].color)
                        .frame(width: 8, height: 8)
                    Text(items[i].label).font(font).foregroundStyle(TTColor.textSecondary)
                        .monospacedDigit().lineLimit(1).fixedSize()
                }
            }
        }
    }
}

// MARK: - Force Quit confirmation

extension ProcessTarget {
    var displayName: String {
        switch self {
        case .app(let identity, _): identity.displayName
        case .process(_, let name, _, _): name
        }
    }
}

/// Installs `\.requestForceQuit` for the page's row menus / inline buttons and presents the confirm dialog
/// (DESIGN §2.26, copy §3.12) over the page. Force Quit always confirms.
struct ForceQuitHost: ViewModifier {
    @Environment(\.processActions) private var actions
    @State private var pending: ProcessTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.requestForceQuit, { target in pending = target })
            .overlay {
                if let target = pending {
                    // Page-level overlay: the shell owns the window, so the scrim covers the page, not the sidebar.
                    TTConfirmDialog(title: "Force quit “\(target.displayName)”?",
                                    message: "Unsaved changes will be lost. The process ends immediately without cleanup.",
                                    confirmTitle: "Force Quit",
                                    onConfirm: {
                                        pending = nil
                                        Task { _ = await actions.forceQuit(target) }
                                    },
                                    onCancel: { pending = nil })
                        .transition(TTConfirmDialog.transition)
                }
            }
            .animation(.easeOut(duration: 0.15), value: pending != nil)
    }
}

extension View {
    func forceQuitHost() -> some View { modifier(ForceQuitHost()) }
}

/// DESIGN §2.20 170-wide actions cell (CPU, Power tables): a selected, controllable row shows [Quit][Force Quit]
/// leading-aligned; otherwise the `…` row-action button, trailing-aligned.
struct InlineActionsCell: View {
    let target: ProcessTarget
    let name: String
    let selected: Bool
    @Environment(\.processActions) private var actions
    @Environment(\.requestForceQuit) private var requestForceQuit

    var body: some View {
        if selected && actions.canControl(target) {
            HStack(spacing: 6) {
                Button("Quit") { Task { _ = await actions.quit(target) } }
                    .buttonStyle(TTButtonStyle(.smallSecondary))
                Button("Force Quit") { requestForceQuit?(target) }
                    .buttonStyle(TTButtonStyle(.smallDestructive))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TTRowActionsButton(target: target, name: name)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
