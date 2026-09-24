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
/// `body12Strong`, chevron 12); value `display` + unit `displayUnit` (Network: "↓ " before the value);
/// sub `caption`; spacer; sparkline full width × 40 (line 1.5, fill 0.22). Hover: border white @ 0.14.
public struct TTMetricTile: View {
    let category: MonitorModel.Category
    let value: String?
    let unit: String?
    let detail: String?
    let points: [SeriesPoint]
    let unavailableReason: String?
    let yDomain: ClosedRange<Double>?
    @State private var hovering = false

    public init(category: MonitorModel.Category, value: String?, unit: String?, detail: String?, points: [SeriesPoint],
                unavailableReason: String?) {
        self.init(category: category, value: value, unit: unit, detail: detail, points: points,
                  unavailableReason: unavailableReason, yDomain: nil)
    }

    /// `yDomain` nil → category default (§5.10), else auto nice ceiling.
    public init(category: MonitorModel.Category, value: String?, unit: String?, detail: String?, points: [SeriesPoint],
                unavailableReason: String?, yDomain: ClosedRange<Double>?) {
        self.category = category
        self.value = value
        self.unit = unit
        self.detail = detail
        self.points = points
        self.unavailableReason = unavailableReason
        self.yDomain = yDomain
    }

    var domain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        if let d = category.ttSparklineDomain { return d }
        let maxValue = points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 0
        return 0...TTFormat.niceCeiling(maxValue, minimum: maxValue > 0 ? 1e-9 : 1)
    }

    private var isAvailable: Bool { value != nil && value != TTFormat.unavailable }

    public var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.x6) {
            HStack(spacing: TTSpace.x7) {
                TTIcon(TTIconName.category(category), size: 16)
                Text(category.ttTitle)
                    .font(TTFont.body12Strong)
                    .foregroundStyle(TTColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TTIcon(.chevronRight, size: 12)
            }
            valueLine.padding(.top, TTSpace.x2)
            Text(detail ?? "")
                .font(TTFont.caption)
                .foregroundStyle(TTColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            TTAreaChart(points, color: TTColor.category(category), yDomain: domain, fillOpacity: TTChartFill.sparkline,
                        lineWidth: TTStroke.spark)
                .frame(height: 40)
        }
        .padding(.vertical, TTSpace.tileVerticalPadding + TTStroke.hairline)
        .padding(.horizontal, TTSpace.cardPadding + TTStroke.hairline)
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168, alignment: .topLeading)
        .ttCardBackground(border: hovering ? TTColor.borderPopover : TTColor.borderCard)
        .contentShape(RoundedRectangle(cornerRadius: TTRadius.card))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var valueLine: some View {
        if !isAvailable {
            MetricValue(nil, unavailableReason: unavailableReason, font: TTFont.display)
        } else if category == .network {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(unit ?? "↓ ").font(TTFont.displayUnit).foregroundStyle(TTColor.textSecondary)
                Text(value ?? "").font(TTFont.display).foregroundStyle(TTColor.textPrimary).lineLimit(1)
            }
            .minimumScaleFactor(0.7)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value ?? "").font(TTFont.display).foregroundStyle(TTColor.textPrimary)
                if let unit {
                    Text(TTUnit.spaced(unit)).font(TTFont.displayUnit).foregroundStyle(TTColor.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}
