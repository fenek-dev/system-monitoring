import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

// Page building blocks shared by the W5a pages (Overview, CPU, GPU, Memory, Network).

// MARK: - Range-aware chart data

/// Chart data for the page's range (DESIGN §3.0 "Range behavior"): Live reads `LiveModel.chartSeries` (last 60 s
/// on the 1-s grid),
/// other ranges read the store (`historyProvider.series(…, bucket: nil)` = the range's display bucket).
struct RangeSeries {
    var range: HistoryRange
    var end: Date
    var points: [HistoryMetric: [SeriesPoint]]

    subscript(_ m: HistoryMetric) -> [SeriesPoint] { points[m] ?? [] }
}

/// Reads `metrics` for `NavigationModel.range` and hands them to `content`.
/// - Live: `LiveModel.series` (re-evaluates per tick, the charts scroll).
/// - Stored ranges: the body never reads the tick. A tiny `BucketClock` child observes the clock and publishes the
///   display-bucket end only when it changes; the store is read in a `.task` keyed by (range, bucket end), and the
///   chart end is that bucket end. A range switch shows no data until the store answers ("Collecting…").
struct RangeSeriesReader<Content: View>: View {
    let metrics: [HistoryMetric]
    @ViewBuilder let content: (RangeSeries) -> Content

    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var now
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]
    @State private var storedKey: LoadKey?
    /// Latest bucket end reported by `BucketClock`, tagged with its range (cleared on a range switch).
    @State private var clock: LoadKey?

    init(_ metrics: [HistoryMetric], @ViewBuilder content: @escaping (RangeSeries) -> Content) {
        self.metrics = metrics
        self.content = content
    }

    struct LoadKey: Equatable {
        var range: HistoryRange
        var bucketEnd: Date
    }

    /// End of the display bucket containing `date` (bucket boundaries on the epoch).
    static func bucketEnd(_ date: Date, range: HistoryRange) -> Date { RangeSeriesReaderBucket.end(date, range: range) }

    /// Store end for `range`: the clock's bucket end only if it was reported for this range, else the fallback
    /// date's bucket end — so the first read after a switch never uses the old range's bucket.
    static func storeEnd(clock: LoadKey?, range: HistoryRange, fallback: Date) -> Date {
        if let clock, clock.range == range { return clock.bucketEnd }
        return bucketEnd(fallback, range: range)
    }

    var body: some View {
        let range = nav.range
        if range == .live {
            content(RangeSeries(range: .live, end: now ?? live.lastUpdate ?? Date(),
                                points: Dictionary(uniqueKeysWithValues: metrics.map { ($0, live.chartSeries($0)) })))
        } else {
            let end = Self.storeEnd(clock: clock, range: range, fallback: now ?? Date())
            let key = LoadKey(range: range, bucketEnd: end)
            content(RangeSeries(range: range, end: end, points: storedKey?.range == range ? stored : [:]))
                .background(BucketClock(range: range) { clock = LoadKey(range: range, bucketEnd: $0) })
                .onChange(of: range) { clock = nil }
                .task(id: key) {
                    let loaded = try? await history.series(metrics, range: range, end: end, bucket: nil)
                    guard !Task.isCancelled else { return }
                    stored = loaded ?? [:]
                    storedKey = key
                }
        }
    }
}

/// Observes the sampling clock (`now` in snapshots, else `LiveModel.lastUpdate`) and reports the display-bucket end
/// only when it moves, so its parent re-renders once per bucket, not per tick.
private struct BucketClock: View {
    let range: HistoryRange
    let onChange: (Date) -> Void
    @Environment(LiveModel.self) private var live
    @Environment(\.now) private var now

    var body: some View {
        let end = RangeSeriesReaderBucket.end(now ?? live.lastUpdate ?? Date(), range: range)
        Color.clear
            .onChange(of: end, initial: true) { onChange(end) }
    }
}

enum RangeSeriesReaderBucket {
    static func end(_ date: Date, range: HistoryRange) -> Date {
        let bucket = Double(range.displayBucket.components.seconds)
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucket).rounded(.up) * bucket)
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

/// Table ranking memoized per `LiveModel.appsVersion` (bumped when processes or apps change), so a re-render that
/// is not caused by new process data does not re-sort.
@MainActor
final class RankCache<Row> {
    private var version = -1
    private var cached: [Row] = []

    func rows(version: Int, _ compute: () -> [Row]) -> [Row] {
        if version != self.version {
            cached = compute()
            self.version = version
        }
        return cached
    }
}

/// `TTTable.columnsVersion` for cells that capture sensor health and unit settings (M2).
@MainActor func tableColumnsVersion(_ live: LiveModel, units: UnitPreferences) -> Int {
    var h = Hasher()
    h.combine(live.healthVersion)
    h.combine(units.temperature.rawValue)
    h.combine(units.networkRate.rawValue)
    return h.finalize()
}

/// DESIGN §5.10: a Live rate chart's scale only grows during the session; stored ranges use the window's own nice
/// ceiling. Held in `@State` and updated during body like `RankCache` (not observed; a range switch starts over).
@MainActor
final class LiveCeilings {
    private var range: HistoryRange?
    private var values: [String: Double] = [:]

    func ceiling(_ key: String, range: HistoryRange, _ value: Double) -> Double {
        if range != self.range {
            self.range = range
            values.removeAll()
        }
        guard range == .live else { return value }
        let v = max(values[key] ?? 0, value.isFinite ? value : 0)
        values[key] = v
        return v
    }

    func domain(_ key: String, range: HistoryRange, _ d: ClosedRange<Double>) -> ClosedRange<Double> {
        d.lowerBound...max(d.lowerBound, ceiling(key, range: range, d.upperBound))
    }
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
@MainActor func metricCell(_ text: String?, reason: String? = nil, estimated: Bool = false,
                           secondary: Bool = false) -> AnyView {
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
/// on a card wide enough for four "DRAM 12.3 W"-sized items (≈ 330 pt; wider windows), else all items in `micro`
/// (the default 300-pt card). Chosen by the card width, not by measuring both variants each tick
/// (`ViewThatFits`, U-M1); the width only changes on a window resize.
struct ColumnLegend: View {
    let items: [(label: String, color: Color)]
    @State private var roomy = false

    nonisolated static let captionMinWidth: CGFloat = 350

    var body: some View {
        (roomy ? row(TTFont.caption, gap: 8) : row(TTFont.micro, gap: 6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.captionMinWidth } action: { roomy = $0 }
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

/// DESIGN §3.12 toast copy for a finished Quit / Force Quit (failures surface as text, §6.7).
enum ActionFeedback {
    enum Kind: Sendable { case quit, forceQuit }

    static func message(_ kind: Kind, _ result: ActionResult, name: String) -> String? {
        let verb = kind == .quit ? "quit" : "force quit"
        switch result {
        case .done: return kind == .quit ? "\(name) quit." : "\(name) was force quit."
        case .cancelled: return nil
        case .notPermitted: return "Not permitted to \(verb) \(name)."
        case .failed(let why): return "Couldn't \(verb) \(name): \(why)"
        }
    }
}

/// Force Quit always confirms (DESIGN §2.25/§3.12): the action runs only after `confirm` returns true.
@MainActor
enum ForceQuitFlow {
    static func run(_ target: ProcessTarget, confirm: () async -> Bool, actions: ProcessActions) async -> ActionResult {
        guard await confirm() else { return .cancelled }
        return await actions.forceQuit(target)
    }

    static func message(_ target: ProcessTarget) -> (title: String, message: String, confirmTitle: String) {
        ("Force quit “\(target.displayName)”?",
         "Unsaved changes will be lost. The process ends immediately without cleanup.", "Force Quit")
    }
}

/// Page host for row actions: installs `\.requestForceQuit` (confirm through the shell's full-window
/// `\.presentConfirmDialog`, then force quit) and `\.onProcessActionResult`, and shows the result as a `TTToast`
/// (§3.12, 4 s). Outside a dashboard window there is no presenter, so Force Quit is not offered.
struct ProcessActionsHost: ViewModifier {
    @Environment(\.processActions) private var actions
    @Environment(\.presentConfirmDialog) private var presenter
    @State private var toast: String?

    private var requestForceQuit: (@MainActor @Sendable (ProcessTarget) -> Void)? {
        guard let presenter else { return nil }
        let actions = actions
        let toast = $toast
        return { target in
            Task { @MainActor in
                let copy = ForceQuitFlow.message(target)
                let result = await ForceQuitFlow.run(target, confirm: {
                    await presenter.confirm(title: copy.title, message: copy.message, confirmTitle: copy.confirmTitle)
                }, actions: actions)
                toast.wrappedValue = ActionFeedback.message(.forceQuit, result, name: target.displayName)
            }
        }
    }

    private var onResult: @MainActor @Sendable (ProcessTarget, ActionResult) -> Void {
        let toast = $toast
        return { target, result in toast.wrappedValue = ActionFeedback.message(.quit, result, name: target.displayName) }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.requestForceQuit, requestForceQuit)
            .environment(\.onProcessActionResult, onResult)
            .overlay(alignment: .bottom) {
                if let toast {
                    TTToast(toast)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: TTRadius.r8).fill(TTColor.bgElevated))
                        .padding(.bottom, 28)
                        .transition(.opacity)
                        .task(id: toast) {
                            try? await Task.sleep(for: TTToast.lifetime)
                            self.toast = nil
                        }
                }
            }
    }
}

extension View {
    func processActionsHost() -> some View { modifier(ProcessActionsHost()) }
}

// MARK: - Exited-processes rows (ICR-13)

extension ProcessSample {
    /// ICR-13 synthetic row (`ProcessID.exitedResidual`): no PID, no row actions, italic secondary, estimated.
    /// Coalition residual rows are NOT exited rows.
    var isExitedResidualRow: Bool { id.isExitedResidual }
}

extension AppSample {
    /// An app group made only of the ICR-13 exited-processes row.
    var isExitedResidualOnly: Bool { !processIDs.isEmpty && processIDs.allSatisfy(\.isExitedResidual) }
}

/// Name cell for an ICR-13 row: tile + italic `textSecondary` name.
struct ExitedNameCell: View {
    let identity: AppIdentity?
    let name: String
    var body: some View {
        HStack(spacing: TTSpace.iconTextGapTable) {
            TTAppTile(identity: identity, name: name, size: 20)
            Text(name).italic().foregroundStyle(TTColor.textSecondary).lineLimit(1).truncationMode(.tail)
        }
    }
}

// MARK: - Inline row actions

/// DESIGN §2.20 170-wide actions cell (CPU, Power tables): a selected row with Quit available shows
/// [Quit][Force Quit] leading-aligned (Force Quit hidden for Telltale itself, whose Quit quits Telltale);
/// otherwise the `…` row-action button, trailing-aligned. ICR-13 rows show nothing.
struct InlineActionsCell: View {
    let target: ProcessTarget
    let name: String
    let selected: Bool
    var exited: Bool = false
    @Environment(\.processActions) private var actions
    @Environment(\.appCommands) private var commands
    @Environment(\.requestForceQuit) private var requestForceQuit
    @Environment(\.onProcessActionResult) private var onResult

    enum Mode: Equatable {
        case none
        case menu
        case inline(forceQuit: Bool, quitsTelltale: Bool)
    }

    /// Pure gating, sharing `TTRowActionsMenu.model`'s self rule (own pid / own bundle id).
    nonisolated static func state(target: ProcessTarget, selected: Bool, canControl: Bool, exited: Bool,
                                  canConfirm: Bool = true, ownPID: Int32 = getpid(),
                                  ownBundleID: String? = Bundle.main.bundleIdentifier) -> Mode {
        if exited { return .none }
        let m = TTRowActionsMenu.model(target: target, canControl: canControl, hasForceQuitHandler: canConfirm,
                                       ownPID: ownPID, ownBundleID: ownBundleID, userName: { _ in "" })
        guard selected, m.quitEnabled else { return .menu }
        return .inline(forceQuit: m.forceQuitVisible && m.forceQuitEnabled, quitsTelltale: m.quitsTelltale)
    }

    var body: some View {
        switch Self.state(target: target, selected: selected, canControl: actions.canControl(target), exited: exited,
                          canConfirm: requestForceQuit != nil) {
        case .none:
            Color.clear.frame(height: 1)
        case .menu:
            TTRowActionsButton(target: target, name: name)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .inline(let forceQuit, let quitsTelltale):
            HStack(spacing: 6) {
                Button("Quit") {
                    if quitsTelltale { commands.quitTelltale(); return }
                    Task { onResult?(target, await actions.quit(target)) }
                }
                .buttonStyle(TTButtonStyle(.smallSecondary))
                if forceQuit {
                    Button("Force Quit") { requestForceQuit?(target) }
                        .buttonStyle(TTButtonStyle(.smallDestructive))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
