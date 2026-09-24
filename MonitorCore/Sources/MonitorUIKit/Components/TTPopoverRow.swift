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
/// - States: hover `fillHover`; expanded white @ 0.06 behind row + expansion; stressed (`level` ≠ calm) row fill in
///   the status color @ 0.12 and the value in the status color.
/// - Expansion (click toggles): padding 0/10/8/36; ≤ 3 lines of 24: tile 16, name `body12` (flex), value in the
///   74 column `body12` `textSecondary`. Thermals shows "by power" above. No apps → "No app activity".
///   Clicking a line → `appCommands.inspectApp`. Double-click the row → `appCommands.openDashboard(page)`.
///   Height animates `.easeInOut(0.18)`.
public struct TTPopoverRow: View {
    let category: MonitorModel.Category
    let subtitle: String?
    let value: String?
    let unavailableReason: String?
    let points: [SeriesPoint]
    let yDomain: ClosedRange<Double>?
    let compact: Bool
    @Binding var expanded: Bool
    let topApps: [AppSample]
    let level: AlertLevel
    @Environment(\.appCommands) private var commands
    @Environment(\.unitPreferences) private var units
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false

    public init(category: MonitorModel.Category, subtitle: String?, value: String?, points: [SeriesPoint],
                compact: Bool, expanded: Binding<Bool>, topApps: [AppSample]) {
        self.init(category: category, subtitle: subtitle, value: value, points: points, compact: compact,
                  expanded: expanded, topApps: topApps, level: .calm)
    }

    /// - `level`: stressed state (thermal/memory/runaway alert on this category).
    /// - `yDomain`: nil → category default (§5.10) or auto nice ceiling.
    public init(category: MonitorModel.Category, subtitle: String?, value: String?, unavailableReason: String? = nil,
                points: [SeriesPoint], yDomain: ClosedRange<Double>? = nil, compact: Bool, expanded: Binding<Bool>,
                topApps: [AppSample], level: AlertLevel) {
        self.category = category
        self.subtitle = subtitle
        self.value = value
        self.unavailableReason = unavailableReason
        self.points = points
        self.yDomain = yDomain
        self.compact = compact
        _expanded = expanded
        self.topApps = topApps
        self.level = level
    }

    // MARK: Expansion content (pure)

    struct Line: Equatable {
        let identity: AppIdentity
        let name: String
        let value: String
    }

    /// Metric per category (§2.22) used to rank and label apps.
    nonisolated static func metricValue(_ app: AppSample, _ category: MonitorModel.Category) -> Double? {
        switch category {
        case .cpu: app.cpuPercent
        case .gpu: app.gpuPercent
        case .memory: app.memory.map { Double($0) }
        case .network: sum(app.netRxBps, app.netTxBps)
        case .thermals, .power: app.energyWatts
        case .disk: sum(app.diskReadBps, app.diskWriteBps)
        }
    }

    nonisolated static func sum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): x + y
        case let (x?, nil): x
        case let (nil, y?): y
        case (nil, nil): nil
        }
    }

    nonisolated static func format(_ v: Double, _ category: MonitorModel.Category, units: UnitPreferences) -> String {
        switch category {
        case .cpu, .gpu: TTFormat.cpuPercent(v)
        case .memory: TTFormat.bytes(UInt64(max(0, v)))
        case .network: TTFormat.rate(v, units: units)
        case .thermals, .power: TTFormat.appWatts(v)
        case .disk: TTFormat.diskRate(v)
        }
    }

    /// Top 3 apps with activity (> 0) on the row's metric, descending.
    nonisolated static func lines(_ apps: [AppSample], _ category: MonitorModel.Category, units: UnitPreferences) -> [Line] {
        apps.compactMap { app -> (AppSample, Double)? in
            guard let v = metricValue(app, category), v.isFinite, v > 0 else { return nil }
            return (app, v)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
        .map { Line(identity: $0.0.identity, name: $0.0.identity.displayName, value: format($0.1, category, units: units)) }
    }

    nonisolated static func page(_ category: MonitorModel.Category) -> DashboardPage {
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

    // MARK: View

    private var stressed: Bool { level != .calm }

    private var background: Color {
        if let fill = TTColor.rowFill(level) { return fill }
        if expanded { return TTColor.fillExpanded }
        return hovering ? TTColor.fillHover : .clear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (compact ? AnyView(compactRow) : AnyView(fullRow))
                .contentShape(Rectangle())
                // Double-click wins exclusively (opens the page, no expansion toggle); a single click toggles.
                .gesture(
                    TapGesture(count: 2).onEnded { commands.openDashboard(Self.page(category)) }
                        .exclusively(before: TapGesture(count: 1).onEnded { toggle() })
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: expanded ? "Collapse" : "Expand") { toggle() }
            if expanded { expansion }
        }
        .background(RoundedRectangle(cornerRadius: TTRadius.r7, style: .continuous).fill(background))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        withAnimation(isSnapshot ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
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
                        lineWidth: TTStroke.sparkThin, showsCollecting: unavailableReason == nil)
                .frame(width: 84, height: 22)
            MetricValue(value, unavailableReason: unavailableReason, font: TTFont.body13Value)
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.85)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, TTSpace.x10)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Hide top apps" : "Show top apps")
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

    private var expansion: some View {
        let lines = Self.lines(topApps, category, units: units)
        return VStack(alignment: .leading, spacing: 0) {
            if category == .thermals && !lines.isEmpty {
                Text("by power").font(TTFont.caption).foregroundStyle(TTColor.textTertiary).frame(height: 18, alignment: .leading)
            }
            if lines.isEmpty {
                Text("No app activity").font(TTFont.caption).foregroundStyle(TTColor.textTertiary).frame(height: 24)
            }
            ForEach(lines.indices, id: \.self) { i in
                let line = lines[i]
                HStack(spacing: TTSpace.x8) {
                    TTAppTile(identity: line.identity, name: line.name, size: 16)
                    Text(line.name).font(TTFont.body12).foregroundStyle(TTColor.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.value).font(TTFont.body12).monospacedDigit().foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                        .frame(width: 74, alignment: .trailing)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture { commands.inspectApp(line.identity.key) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.leading, 36)
        .padding(.trailing, TTSpace.x10)
        .padding(.bottom, TTSpace.x8)
        .transition(.opacity)
    }
}
