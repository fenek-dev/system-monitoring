import Charts
import MonitorModel
import SwiftUI

/// DESIGN §2.9 multi-line chart with a y-label column: HStack gap 10 of 5 labels (`micro` `textTertiary`,
/// space-between, top = upper bound) and the plot (lines only; widths from each series, default 1.5).
/// Swift Charts (page chart); points capped at 600 in total by min/max decimation (ARCHITECTURE §7).
/// Gaps break lines (each run is its own mark series). Faint gridlines at quarters.
public struct TTLineChart: View, Equatable {
    struct LineStyle: Equatable, Sendable {
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
    }

    struct Mark: Identifiable, Equatable, Sendable {
        let id: Int
        let run: String
        let time: Date
        let value: Double
        let seriesIndex: Int
    }

    static let maxTotalPoints = 600

    let marks: [Mark]
    let styles: [LineStyle]
    let summary: String
    let yDomain: ClosedRange<Double>
    let xDomain: ClosedRange<Date>?
    let labels: [String]
    /// Explicit y ticks (ICR, W5b): labels and inner gridlines at these values; nil = 5 labels / gridlines at quarters.
    let yTicks: [Double]?
    let sampleCount: Int

    /// - Parameter yTicks: explicit tick values (labels at each, gridlines at those strictly inside the domain),
    ///   e.g. `[100, 80, 60, 40, 20]` for a 20…105 domain. nil keeps the quarter labels and gridlines.
    public init(_ series: [ChartSeries], yDomain: ClosedRange<Double>, yTicks: [Double]? = nil,
                yFormat: @escaping (Double) -> String) {
        self.yDomain = yDomain
        self.yTicks = yTicks
        let perSeries = max(2, Self.maxTotalPoints / max(1, series.count))
        var marks: [Mark] = []
        var minT: Date?, maxT: Date?
        var samples = 0
        for (si, s) in series.enumerated() {
            let pts = ChartSegments.decimate(s.points, maxPoints: perSeries)
            if let f = pts.first?.time { minT = min(minT ?? f, f) }
            if let l = pts.last?.time { maxT = max(maxT ?? l, l) }
            for (ri, run) in ChartSegments.runs(pts).enumerated() {
                for i in run {
                    marks.append(Mark(id: marks.count, run: "\(s.id)#\(ri)", time: pts[i].time,
                                      value: pts[i].value!, seriesIndex: si))
                }
            }
            samples = max(samples, ChartSegments.sampleCount(pts))
        }
        self.marks = marks
        styles = series.map { LineStyle(color: $0.color.opacity($0.lineOpacity), width: $0.lineWidth ?? TTStroke.spark, dash: $0.dash) }
        summary = ChartAccessibility.summary(series, format: yFormat)
        if let minT, let maxT, maxT > minT { xDomain = minT...maxT } else { xDomain = nil }
        labels = yTicks.map { $0.map(yFormat) }
            ?? (0..<5).map { k in yFormat(yDomain.upperBound - Double(k) / 4 * (yDomain.upperBound - yDomain.lowerBound)) }
        sampleCount = samples
    }

    /// Fraction of the plot height from the top (upper bound = 0, lower bound = 1).
    nonisolated static func fraction(_ v: Double, in domain: ClosedRange<Double>) -> Double {
        (domain.upperBound - v) / max(domain.upperBound - domain.lowerBound, .leastNonzeroMagnitude)
    }

    /// Gridline fractions: quarters, or the ticks strictly inside the domain.
    nonisolated static func gridFractions(yTicks: [Double]?, domain: ClosedRange<Double>) -> [Double] {
        guard let yTicks else { return [0.25, 0.5, 0.75] }
        return yTicks.filter { $0 > domain.lowerBound && $0 < domain.upperBound }.map { fraction($0, in: domain) }
    }

    public var body: some View {
        HStack(spacing: TTSpace.x10) {
            labelColumn
                .accessibilityHidden(true)
            plot
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    @ViewBuilder private var labelColumn: some View {
        if let yTicks {
            TickLabelsLayout(fractions: yTicks.map { Self.fraction($0, in: yDomain) }) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i]).font(TTFont.micro).foregroundStyle(TTColor.textTertiary).lineLimit(1).fixedSize()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i]).font(TTFont.micro).foregroundStyle(TTColor.textTertiary).lineLimit(1)
                    if i < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder private var plot: some View {
        let grid = Self.gridFractions(yTicks: yTicks, domain: yDomain)
        if sampleCount < 2 {
            ZStack {
                TTChartCanvas { ctx, size in Self.drawGrid(&ctx, size: size, fractions: grid) }
                TTEmptyState(.collecting(since: nil))
            }
        } else {
            ZStack {
                TTChartCanvas { ctx, size in Self.drawGrid(&ctx, size: size, fractions: grid) }
                chart
            }
        }
    }

    /// Same stroke as `ChartGrid` (white @ 0.06, 1 pt, centered on the exact fraction).
    private static func drawGrid(_ ctx: inout GraphicsContext, size: CGSize, fractions: [Double]) {
        var path = Path()
        for f in fractions {
            let y = size.height * f
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(path, with: .color(ChartGrid.color), lineWidth: 1)
    }

    private var chart: some View {
        Chart(marks) { m in
            let style = styles[m.seriesIndex]
            LineMark(x: .value("t", m.time), y: .value("v", min(max(m.value, yDomain.lowerBound), yDomain.upperBound)),
                     series: .value("run", m.run))
                .foregroundStyle(style.color)
                .lineStyle(StrokeStyle(lineWidth: style.width, lineCap: .butt, lineJoin: .round, dash: style.dash))
                .interpolationMethod(.linear)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .modifier(XDomain(domain: xDomain))
        .chartPlotStyle { $0.frame(maxWidth: .infinity, maxHeight: .infinity) }
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }

    private struct XDomain: ViewModifier {
        let domain: ClosedRange<Date>?
        func body(content: Content) -> some View {
            if let domain { content.chartXScale(domain: domain) } else { content }
        }
    }

    /// Tick labels: each centered on its fraction of the height, clamped inside; width = widest label.
    private struct TickLabelsLayout: Layout {
        let fractions: [Double]

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            return CGSize(width: w, height: proposal.height ?? 150)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for (i, s) in subviews.enumerated() where i < fractions.count {
                let size = s.sizeThatFits(.unspecified)
                let y = min(max(bounds.height * fractions[i] - size.height / 2, 0), bounds.height - size.height)
                s.place(at: CGPoint(x: bounds.minX, y: bounds.minY + y), anchor: .topLeading, proposal: .unspecified)
            }
        }
    }
}
