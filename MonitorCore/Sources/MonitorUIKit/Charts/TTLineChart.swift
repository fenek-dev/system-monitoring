import Charts
import MonitorModel
import SwiftUI

/// DESIGN §2.9 multi-line chart with a y-label column: HStack gap 10 of 5 labels (`micro` `textTertiary`,
/// space-between, top = upper bound) and the plot (lines only; widths from each series, default 1.5).
/// Swift Charts (page chart); points capped at 600 in total by min/max decimation (ARCHITECTURE §7).
/// Gaps break lines (each run is its own mark series). Faint gridlines at quarters.
public struct TTLineChart: View {
    struct Mark: Identifiable {
        let id: Int
        let run: String
        let time: Date
        let value: Double
        let seriesIndex: Int
    }

    static let maxTotalPoints = 600

    let marks: [Mark]
    let styles: [(color: Color, width: CGFloat, dash: [CGFloat])]
    let yDomain: ClosedRange<Double>
    let xDomain: ClosedRange<Date>?
    let labels: [String]
    let sampleCount: Int

    public init(_ series: [ChartSeries], yDomain: ClosedRange<Double>, yFormat: @escaping (Double) -> String) {
        self.yDomain = yDomain
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
        styles = series.map { ($0.color.opacity($0.lineOpacity), $0.lineWidth ?? TTStroke.spark, $0.dash) }
        if let minT, let maxT, maxT > minT { xDomain = minT...maxT } else { xDomain = nil }
        labels = (0..<5).map { k in yFormat(yDomain.upperBound - Double(k) / 4 * (yDomain.upperBound - yDomain.lowerBound)) }
        sampleCount = samples
    }

    public var body: some View {
        HStack(spacing: TTSpace.x10) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i]).font(TTFont.micro).foregroundStyle(TTColor.textTertiary).lineLimit(1)
                    if i < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            plot
        }
    }

    @ViewBuilder private var plot: some View {
        if sampleCount < 2 {
            ZStack {
                TTChartCanvas { ctx, size in ChartGrid.draw(&ctx, size: size, divisions: 4) }
                TTEmptyState(.collecting(since: nil))
            }
        } else {
            ZStack {
                TTChartCanvas { ctx, size in ChartGrid.draw(&ctx, size: size, divisions: 4) }
                chart
            }
        }
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
}
