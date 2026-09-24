import MonitorModel
import SwiftUI

public extension MonitorModel.Category {
    /// Display title ("CPU", "Memory", …; Power's popover/tile title is "Power").
    var ttTitle: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .thermals: "Thermals"
        case .power: "Power"
        case .disk: "Disk"
        }
    }

    /// Default sparkline domain when none is given (DESIGN §5.10): usage fractions 0…1 for CPU/GPU,
    /// 0–100 °C for thermals; nil = auto (nice ceiling of the window max).
    var ttSparklineDomain: ClosedRange<Double>? {
        switch self {
        case .cpu, .gpu: 0...1
        case .thermals: 0...100
        case .memory, .network, .power, .disk: nil
        }
    }
}

/// DESIGN §2.4 Overview metric tile: card padding 14×16, height 168, VStack gap 6; header (icon 16, title
/// `body12Strong`, chevron 12); value `display` with `prefix` ("↓ ", Network) and `unit` in `displayUnit`;
/// sub `caption`; spacer; sparkline full width × 40 (line 1.5, fill 0.22).
/// With an `action` the tile is a button: hover border white @ 0.14, pressed bg white @ 0.03.
public struct TTMetricTile: View, Equatable {
    let category: MonitorModel.Category
    let value: String?
    let prefix: String?
    let unit: String?
    let detail: String?
    let points: [SeriesPoint]
    let unavailableReason: String?
    let yDomain: ClosedRange<Double>?
    let action: (@MainActor () -> Void)?
    let showsCollecting: Bool

    /// Legacy form: for Network a `unit` of "↓ " is treated as the prefix.
    public init(category: MonitorModel.Category, value: String?, unit: String?, detail: String?, points: [SeriesPoint],
                unavailableReason: String?) {
        self.init(category: category, value: value, unit: unit, detail: detail, points: points,
                  unavailableReason: unavailableReason, yDomain: nil)
    }

    /// - `yDomain`: nil → category default (§5.10), else auto nice ceiling.
    /// - `showsCollecting`: "Collecting…" when the sparkline has < 2 samples. nil = automatic: collecting unless
    ///   `unavailableReason` is set (an unavailable sensor shows "—" + tooltip and an empty chart, DESIGN §3.15).
    public init(category: MonitorModel.Category, value: String?, prefix: String? = nil, unit: String?, detail: String?,
                points: [SeriesPoint], unavailableReason: String?, yDomain: ClosedRange<Double>?,
                showsCollecting: Bool? = nil, action: (@MainActor () -> Void)? = nil) {
        self.showsCollecting = showsCollecting ?? (unavailableReason == nil)
        self.category = category
        self.value = value
        if prefix == nil, category == .network, let unit, unit.hasPrefix("↓") || unit.hasPrefix("↑") {
            self.prefix = unit
            self.unit = nil
        } else {
            self.prefix = prefix
            self.unit = unit
        }
        self.detail = detail
        self.points = points
        self.unavailableReason = unavailableReason
        self.yDomain = yDomain
        self.action = action
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.category == b.category && a.value == b.value && a.prefix == b.prefix && a.unit == b.unit && a.detail == b.detail
            && a.points == b.points && a.unavailableReason == b.unavailableReason && a.yDomain == b.yDomain
            && a.showsCollecting == b.showsCollecting
            && (a.action == nil) == (b.action == nil)
    }

    var domain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        if let d = category.ttSparklineDomain { return d }
        let maxValue = points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 0
        return 0...TTFormat.niceCeiling(maxValue, minimum: maxValue > 0 ? 1e-9 : 1)
    }

    public var body: some View {
        if let action {
            Button(action: action) { content(pressed: false) }
                .buttonStyle(TilePressStyle(tile: self))
        } else {
            content(pressed: false)
        }
    }

    func content(pressed: Bool) -> some View {
        TileContent(tile: self, pressed: pressed)
    }

    private struct TilePressStyle: ButtonStyle {
        let tile: TTMetricTile
        func makeBody(configuration: Configuration) -> some View {
            TileContent(tile: tile, pressed: configuration.isPressed)
        }
    }

    private struct TileContent: View {
        let tile: TTMetricTile
        let pressed: Bool
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: TTSpace.x6) {
                HStack(spacing: TTSpace.x7) {
                    TTIcon(TTIconName.category(tile.category), size: 16)
                    Text(tile.category.ttTitle)
                        .font(TTFont.body12Strong)
                        .foregroundStyle(TTColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TTIcon(.chevronRight, size: 12)
                }
                valueLine.padding(.top, TTSpace.x2)
                Text(tile.detail ?? "")
                    .font(TTFont.caption)
                    .foregroundStyle(TTColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                TTAreaChart(tile.points, color: TTColor.category(tile.category), yDomain: tile.domain,
                            fillOpacity: TTChartFill.sparkline, lineWidth: TTStroke.spark,
                            showsCollecting: tile.showsCollecting)
                    .frame(height: 40)
            }
            .padding(.vertical, TTSpace.tileVerticalPadding + TTStroke.hairline)
            .padding(.horizontal, TTSpace.cardPadding + TTStroke.hairline)
            .frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168, alignment: .topLeading)
            .ttCardBackground(border: hovering && tile.action != nil ? TTColor.borderPopover : TTColor.borderCard)
            .overlay {
                if pressed {
                    RoundedRectangle(cornerRadius: TTRadius.card, style: .continuous).fill(Color.white.opacity(0.03))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: TTRadius.card))
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tile.category.ttTitle)
            .accessibilityValue([TTUnit.join(tile.value, tile.unit).map { (tile.prefix ?? "") + $0 } ?? "unavailable",
                                 tile.detail ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(tile.action != nil ? .isButton : [])
        }

        @ViewBuilder private var valueLine: some View {
            if !(tile.value != nil && tile.value != TTFormat.unavailable) {
                MetricValue(nil, unavailableReason: tile.unavailableReason, font: TTFont.display)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let prefix = tile.prefix {
                        Text(prefix).font(TTFont.displayUnit).foregroundStyle(TTColor.textSecondary)
                    }
                    Text(tile.value ?? "").font(TTFont.display).foregroundStyle(TTColor.textPrimary)
                    if let unit = tile.unit {
                        Text(TTUnit.spaced(unit)).font(TTFont.displayUnit).foregroundStyle(TTColor.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }
}
