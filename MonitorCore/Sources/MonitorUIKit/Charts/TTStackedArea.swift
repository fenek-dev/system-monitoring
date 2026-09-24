import MonitorModel
import SwiftUI

/// DESIGN §2.7 stacked area: `series` in stacking order (bottom first, e.g. [CPU, GPU, ANE, DRAM] or
/// [User, System]). Cumulative layers are drawn from the largest sum down, each filled from the baseline in the
/// color of its top series @ its `fillOpacity` (layers overlap, not banded). Optional outline of the total
/// (CPU usage: `cpuLine` 1.25 @ 0.9). Page gridlines at quarters. A gap in any series is a gap in every layer
/// above it. Canvas.
public struct TTStackedArea: View, Equatable {
    let layers: [[SeriesPoint]]
    let colors: [Color]
    let yDomain: ClosedRange<Double>
    let outline: Color?
    let outlineWidth: CGFloat
    let grid: Int
    let summary: String

    public init(_ series: [ChartSeries], yDomain: ClosedRange<Double>) {
        self.init(series, yDomain: yDomain, outline: nil)
    }

    public init(_ series: [ChartSeries], yDomain: ClosedRange<Double>, outline: Color?,
                outlineWidth: CGFloat = TTStroke.sparkThin, grid: Int = 4) {
        layers = Self.cumulative(series.map(\.points))
        summary = ChartAccessibility.summary(series)
        colors = series.map { $0.color.opacity($0.fillOpacity ?? 1) }
        self.yDomain = yDomain
        self.outline = outline
        self.outlineWidth = outlineWidth
        self.grid = grid
    }

    /// Running sums per index; nil when any contributing series is missing there.
    nonisolated static func cumulative(_ series: [[SeriesPoint]]) -> [[SeriesPoint]] {
        guard let first = series.first else { return [] }
        var result: [[SeriesPoint]] = [first]
        result.reserveCapacity(series.count)
        for s in series.dropFirst() {
            let prev = result[result.count - 1]
            let n = min(prev.count, s.count)
            var layer = [SeriesPoint]()
            layer.reserveCapacity(n)
            // Align on the newest samples when lengths differ.
            let po = prev.count - n, so = s.count - n
            for i in 0..<n {
                let a = prev[po + i].value, b = s[so + i].value
                let v: Double? = if let a, let b, a.isFinite, b.isFinite { a + b } else { nil }
                layer.append(SeriesPoint(time: s[so + i].time, value: v))
            }
            result.append(layer)
        }
        return result
    }

    public var body: some View {
        if ChartSegments.sampleCount(layers.last ?? []) < 2 {
            ZStack {
                TTChartCanvas { ctx, size in ChartGrid.draw(&ctx, size: size, divisions: 4) }
                TTEmptyState(.collecting(since: nil))
            }
        } else {
            let chart = self
            let bridge = gapBridge
            TTChartCanvas { ctx, size in chart.draw(&ctx, size: size, bridge: bridge) }
                .accessibilityElement()
                .accessibilityLabel(summary)
        }
    }

    /// `\.ttChartGapBridge` (Live 1-s grid): short nil runs are spanned; a lone sample draws as a dot (ruling N2).
    @Environment(\.ttChartGapBridge) private var gapBridge

    /// Data equality (the environment is tracked by SwiftUI separately).
    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.layers == b.layers && a.colors == b.colors && a.yDomain == b.yDomain && a.outline == b.outline
            && a.outlineWidth == b.outlineWidth && a.grid == b.grid && a.summary == b.summary
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, bridge: Int = 0) {
        ChartGrid.draw(&ctx, size: size, divisions: grid)
        for i in layers.indices.reversed() {
            var line = Path()
            var area: Path? = Path()
            ChartSegments.addSeries(layers[i], domain: yDomain, in: size, line: &line, area: &area, bridge: bridge)
            if let area { ctx.fill(area, with: .color(colors[i])) }
            ctx.fill(ChartSegments.loneDots(layers[i], domain: yDomain, in: size, radius: 1.5, bridge: bridge),
                     with: .color(colors[i]))
        }
        if let outline, let top = layers.last {
            var line = Path()
            var none: Path?
            ChartSegments.addSeries(top, domain: yDomain, in: size, line: &line, area: &none, bridge: bridge)
            ctx.stroke(line, with: .color(outline),
                       style: StrokeStyle(lineWidth: outlineWidth, lineCap: .butt, lineJoin: .round))
        }
    }
}
