import MonitorModel
import SwiftUI

/// DESIGN §2.5 timeline row: HStack gap 12, height 34: label box 84 (icon 14 + `body12` `textSecondary`, gap 7),
/// sparkline 480×30 (line 1.25, fill 0.18; `chartWidth: nil` fills the width as in App detail), value (flex,
/// right-aligned, `body12` `textPrimary`). Rows stack with gap 4; the axis below is inset 96.
public struct TTTimelineRow: View, Equatable {
    let label: String
    let icon: TTIconName?
    let value: String?
    let unavailableReason: String?
    let points: [SeriesPoint]
    let color: Color
    let yDomain: ClosedRange<Double>
    let chartWidth: CGFloat?
    let height: CGFloat
    let showsCollecting: Bool

    public init(label: String, value: String?, points: [SeriesPoint], color: Color, yDomain: ClosedRange<Double>) {
        self.init(label: label, icon: nil, value: value, points: points, color: color, yDomain: yDomain)
    }

    /// - Parameters:
    ///   - icon: nil → derived from the label ("CPU", "GPU", "Memory", "Network", "Thermals", "Disk", "Energy"/"Power").
    ///   - chartWidth: 480 on Overview; nil fills the available width (App detail).
    ///   - height: row height (34; App detail rows use 30-tall sparklines in 34-tall rows).
    ///   - showsCollecting: nil = automatic — "Collecting…" for < 2 samples unless `unavailableReason` is set
    ///     (unavailable: "—" + tooltip, empty chart; DESIGN §3.15).
    public init(label: String, icon: TTIconName?, value: String?, unavailableReason: String? = nil, points: [SeriesPoint],
                color: Color, yDomain: ClosedRange<Double>, chartWidth: CGFloat? = 480, height: CGFloat = 34,
                showsCollecting: Bool? = nil) {
        self.showsCollecting = showsCollecting ?? (unavailableReason == nil)
        self.label = label
        self.icon = icon ?? Self.icon(for: label)
        self.value = value
        self.unavailableReason = unavailableReason
        self.points = points
        self.color = color
        self.yDomain = yDomain
        self.chartWidth = chartWidth
        self.height = height
    }

    static func icon(for label: String) -> TTIconName? {
        switch label.lowercased() {
        case "cpu": .cpu
        case "gpu": .gpu
        case "memory": .memory
        case "network": .network
        case "thermals", "temperature": .thermals
        case "disk": .disk
        case "energy", "power": .power
        default: nil
        }
    }

    public var body: some View {
        HStack(spacing: TTSpace.x12) {
            HStack(spacing: TTSpace.x7) {
                if let icon { TTIcon(icon, size: 14) }
                Text(label).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
            }
            .frame(width: 84, alignment: .leading)
            TTAreaChart(points, color: color, yDomain: yDomain, fillOpacity: TTChartFill.timeline,
                        lineWidth: TTStroke.sparkThin, showsCollecting: showsCollecting)
                .frame(maxWidth: chartWidth ?? .infinity)
                .frame(width: chartWidth, height: 30)
            MetricValue(value, unavailableReason: unavailableReason, font: TTFont.body12)
                .foregroundStyle(TTColor.textPrimary)
                .layoutPriority(1)               // fixed layout, no scale-to-fit pass per tick (U-M1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
    }
}
