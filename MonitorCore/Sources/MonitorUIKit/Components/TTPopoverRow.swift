import MonitorModel
import SwiftUI

/// DESIGN §3.1 popover divider: 1-pt `separator`, margin 4 vertical × 10 horizontal.
public struct TTPopoverDivider: View {
    public init() {}
    public var body: some View {
        TTSeparator().padding(.vertical, TTSpace.x4).padding(.horizontal, TTSpace.x10)
    }
}

/// DESIGN §2.22 popover category row.
/// - Full (44): icon 16 · VStack(title `body13`, sub `caption` `textSecondary`) flex · sparkline 84×22 (1.25 / 0.22)
///   · value 74 wide right-aligned `body13Value` (scales to 0.85).
/// - Compact (36; Power, Disk): `body12` tabular: icon · title (flex) · detail `textSecondary` · value 74 semibold.
/// - States: hover `fillHover`; stressed (`level` ≠ calm) row fill in the status color @ 0.12 and the value in the
///   status color.
/// - A click opens the category's dashboard page (`appCommands.openDashboard`). Hover enter/exit (with the row's
///   frame) and the "Show top apps" accessibility action go to `\.popoverRowHover` — the App's top-apps flyout.
public struct TTPopoverRow: View {
    let category: MonitorModel.Category
    let subtitle: String?
    let value: String?
    let unavailableReason: String?
    let points: [SeriesPoint]
    let yDomain: ClosedRange<Double>?
    let compact: Bool
    let level: AlertLevel
    let showsCollecting: Bool
    let highlighted: Bool
    @Environment(\.appCommands) private var commands
    @Environment(\.popoverRowHover) private var hoverSink
    @State private var hovering = false
    @State private var frame = CGRect.zero

    /// - `level`: stressed state (thermal/memory/runaway alert on this category).
    /// - `yDomain`: nil → category default (§5.10) or auto nice ceiling.
    /// - `showsCollecting`: sparkline "Collecting…" below 2 samples; nil = automatic (unless `unavailableReason`).
    /// - `highlighted`: the row's top-apps flyout is shown → `fillHover` as if hovered.
    public init(category: MonitorModel.Category, subtitle: String?, value: String?, unavailableReason: String? = nil,
                points: [SeriesPoint], yDomain: ClosedRange<Double>? = nil, compact: Bool, level: AlertLevel = .calm,
                showsCollecting: Bool? = nil, highlighted: Bool = false) {
        self.showsCollecting = showsCollecting ?? (unavailableReason == nil)
        self.highlighted = highlighted
        self.category = category
        self.subtitle = subtitle
        self.value = value
        self.unavailableReason = unavailableReason
        self.points = points
        self.yDomain = yDomain
        self.compact = compact
        self.level = level
    }

    // MARK: Per-category app metric (pure; shared with the flyout)

    /// Metric per category (§2.22) used to rank and label apps.
    public nonisolated static func metricValue(_ app: AppSample, _ category: MonitorModel.Category) -> Double? {
        switch category {
        case .cpu: app.cpuPercent
        case .gpu: app.gpuPercent
        case .memory: app.memory.map { Double($0) }
        case .network: sum(app.netRxBps, app.netTxBps)
        case .thermals, .power: app.energyWatts
        case .disk: sum(app.diskReadBps, app.diskWriteBps)
        }
    }

    /// nil only when both are nil.
    public nonisolated static func sum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): x + y
        case let (x?, nil): x
        case let (nil, y?): y
        case (nil, nil): nil
        }
    }

    public nonisolated static func format(_ v: Double, _ category: MonitorModel.Category,
                                          units: UnitPreferences) -> String {
        switch category {
        case .cpu, .gpu: TTFormat.cpuPercent(v)
        case .memory: TTFormat.bytes(UInt64(max(0, v)))
        case .network: TTFormat.rate(v, units: units)
        case .thermals, .power: TTFormat.appWatts(v)
        case .disk: TTFormat.diskRate(v)
        }
    }

    public nonisolated static func page(_ category: MonitorModel.Category) -> DashboardPage {
        switch category {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .thermals: .thermals
        case .power: .power
        case .disk: .disk
        }
    }

    // MARK: Behaviour (pure, tested)

    /// Single click: the category's dashboard page.
    @MainActor static func click(_ category: MonitorModel.Category, commands: AppCommands) {
        commands.openDashboard(page(category))
    }

    /// "Show top apps" (keyboard / VoiceOver): the flyout for this row, now.
    @MainActor static func showTopApps(_ category: MonitorModel.Category, frame: CGRect,
                                       sink: (@MainActor @Sendable (PopoverRowHover) -> Void)?) {
        sink?(PopoverRowHover(category: category, phase: .show, frame: frame))
    }

    // MARK: View

    private var stressed: Bool { level != .calm }

    private var background: Color {
        if let fill = TTColor.rowFill(level) { return fill }
        return hovering || highlighted ? TTColor.fillHover : .clear
    }

    public var body: some View {
        (compact ? AnyView(compactRow) : AnyView(fullRow))
            .contentShape(Rectangle())
            .onTapGesture { Self.click(category, commands: commands) }
            .background(RoundedRectangle(cornerRadius: TTRadius.r7, style: .continuous).fill(background))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                frame = f
                hoverSink?(PopoverRowHover(category: category, phase: .geometry, frame: f))
            }
            .onHover { inside in
                hovering = inside
                hoverSink?(PopoverRowHover(category: category, phase: inside ? .entered : .exited, frame: frame))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Open \(category.ttTitle)")
            .accessibilityAction(named: "Show top apps") {
                Self.showTopApps(category, frame: frame, sink: hoverSink)
            }
    }

    private var valueColor: Color { stressed ? TTColor.level(level) : TTColor.textPrimary }

    private var fullRow: some View {
        HStack(spacing: TTSpace.iconTextGapPopover) {
            TTIcon(TTIconName.category(category), size: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(category.ttTitle).font(TTFont.body13).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                Text(subtitle ?? "").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TTAreaChart(points, color: TTColor.category(category), yDomain: domain, fillOpacity: TTChartFill.sparkline,
                        lineWidth: TTStroke.sparkThin, showsCollecting: showsCollecting)
                .frame(width: 84, height: 22)
            MetricValue(value, unavailableReason: unavailableReason, font: TTFont.body13Value)
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.85)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, TTSpace.x10)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    private var compactRow: some View {
        HStack(spacing: TTSpace.iconTextGapPopover) {
            TTIcon(TTIconName.category(category), size: 16)
            Text(category.ttTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The title is the flex spacer; the detail keeps its natural width (truncates only when it can't fit).
            Text(subtitle ?? "").foregroundStyle(TTColor.textSecondary).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            MetricValue(value, unavailableReason: unavailableReason, font: TTFont.body12Strong)
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.85)
                .frame(width: 74, alignment: .trailing)
        }
        .font(TTFont.body12)
        .padding(.horizontal, TTSpace.x10)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }

    private var domain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        if let d = category.ttSparklineDomain { return d }
        let maxValue = points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 0
        return 0...TTFormat.niceCeiling(maxValue, minimum: maxValue > 0 ? 1e-9 : 1)
    }
}
