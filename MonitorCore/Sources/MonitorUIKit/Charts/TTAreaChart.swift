import MonitorModel
import SwiftUI

/// DESIGN §2.3 sparkline / area chart, drawn with `Canvas` (ARCHITECTURE §7).
/// Optional grid (page charts: lines at each 1/`grid`) and bands under the series; then area (series color @
/// `fillOpacity`) and line (`lineWidth`, butt caps, round joins). x even over N samples, y clamped to `yDomain`;
/// gaps break line and area; the line may bleed past the frame. Fewer than 2 samples → "Collecting…" (§3.15).
/// Draws in a single pass (no intermediate arrays); decimates only when N > 2 × width.
public struct TTAreaChart: View, Equatable {
    let points: [SeriesPoint]
    let color: Color
    let yDomain: ClosedRange<Double>
    let fillOpacity: Double
    let lineOnly: Bool
    let lineWidth: CGFloat
    let flipped: Bool
    let dash: [CGFloat]
    let grid: Int
    let bands: [TTChartBand]
    let showsCollecting: Bool
    let partialHistory: Bool

    /// - Parameters:
    ///   - fillOpacity: area opacity applied to `color` (`TTChartFill`, e.g. `.sparkline` 0.22).
    ///   - flipped: area hangs down from the top edge (mirrored chart bottom half).
    ///   - grid: number of divisions for the faint page-chart gridlines (0 = none; page charts use 4).
    ///   - partialHistory: stored ranges (DESIGN §3.15 "Partial history", U-M6): the leading run with no sample
    ///     (before the first stored bucket) is `fillTrack` with "No data yet" when ≥ 60 wide, and a loaded window
    ///     with fewer than 2 samples reads "No data yet" instead of "Collecting…" (an empty one is still loading).
    public init(_ points: [SeriesPoint], color: Color, yDomain: ClosedRange<Double>, fillOpacity: Double = 1,
                lineOnly: Bool = false, lineWidth: CGFloat = TTStroke.spark, flipped: Bool = false, dash: [CGFloat] = [],
                grid: Int = 0, bands: [TTChartBand] = [], showsCollecting: Bool = true, partialHistory: Bool = false) {
        self.partialHistory = partialHistory
        self.points = points
        self.color = color
        self.yDomain = yDomain
        self.fillOpacity = fillOpacity
        self.lineOnly = lineOnly
        self.lineWidth = lineWidth
        self.flipped = flipped
        self.dash = dash
        self.grid = grid
        self.bands = bands
        self.showsCollecting = showsCollecting
    }

    /// Room around the frame so the line can bleed past it.
    static let bleed: CGFloat = 2

    public var body: some View {
        if showsCollecting && ChartSegments.sampleCount(points) < 2 {
            ZStack {
                if grid > 1 { TTChartCanvas { ctx, size in ChartGrid.draw(&ctx, size: size, divisions: grid) } }
                // An empty window is a store read still in flight ("Collecting…"); a loaded one with < 2 samples
                // has no history yet.
                if partialHistory && !points.isEmpty {
                    Rectangle().fill(TTColor.fillTrack)
                    Text("No data yet").font(TTFont.micro).foregroundStyle(TTColor.textTertiary)
                } else {
                    TTEmptyState(.collecting(since: nil))
                }
            }
        } else {
            let chart = self
            let bridge = gapBridge
            TTChartCanvas { ctx, size in chart.draw(&ctx, size: size, bridge: bridge) }
                .accessibilityHidden(true)
        }
    }

    /// `\.ttChartGapBridge` (Live 1-s grid): short nil runs between samples are spanned; lone samples draw as dots.
    @Environment(\.ttChartGapBridge) private var gapBridge

    /// Data equality (the environment is tracked by SwiftUI separately).
    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.points == b.points && a.color == b.color && a.yDomain == b.yDomain && a.fillOpacity == b.fillOpacity
            && a.lineOnly == b.lineOnly && a.lineWidth == b.lineWidth && a.flipped == b.flipped && a.dash == b.dash
            && a.grid == b.grid && a.bands == b.bands && a.showsCollecting == b.showsCollecting
            && a.partialHistory == b.partialHistory
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, bridge: Int = 0) {
        for band in bands {
            let y0 = ChartSegments.y(value: band.range.upperBound, domain: yDomain, height: size.height)
            let y1 = ChartSegments.y(value: band.range.lowerBound, domain: yDomain, height: size.height)
            ctx.fill(Path(CGRect(x: 0, y: y0, width: size.width, height: y1 - y0)), with: .color(band.color))
        }
        ChartGrid.draw(&ctx, size: size, divisions: grid)
        if partialHistory, let first = points.firstIndex(where: { $0.value?.isFinite == true }), first > 0 {
            let x1 = ChartSegments.x(index: first, count: points.count, width: size.width)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x1, height: size.height)), with: .color(TTColor.fillTrack))
            if x1 >= 60 {
                ctx.draw(Text("No data yet").font(TTFont.micro).foregroundStyle(TTColor.textTertiary),
                         at: CGPoint(x: x1 / 2, y: size.height / 2))
            }
        }
        let limit = max(2, Int(size.width * 2))
        let drawn = points.count > limit ? ChartSegments.decimate(points, maxPoints: limit) : points
        var line = Path()
        var area: Path? = lineOnly ? nil : Path()
        // Decimated series (N > 2 × width) are not grid data: no bridging there.
        let b = drawn.count == points.count ? bridge : 0
        ChartSegments.addSeries(drawn, domain: yDomain, in: size, line: &line, area: &area, flipped: flipped, bridge: b)
        if let area { ctx.fill(area, with: .color(color.opacity(fillOpacity))) }
        ctx.stroke(line, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round, dash: dash))
        ctx.fill(ChartSegments.loneDots(drawn, domain: yDomain, in: size, radius: max(1.5, lineWidth),
                                        flipped: flipped, bridge: b),
                 with: .color(color))
    }
}

/// A `Canvas` that extends `TTAreaChart.bleed` past its frame so strokes on the edges are not clipped;
/// the drawing closure sees the unextended size with the origin at the frame's top-left.
struct TTChartCanvas: View {
    let draw: (inout GraphicsContext, CGSize) -> Void

    init(_ draw: @escaping (inout GraphicsContext, CGSize) -> Void) { self.draw = draw }

    var body: some View {
        let b = TTAreaChart.bleed
        Canvas(rendersAsynchronously: false) { ctx, canvasSize in
            ctx.translateBy(x: b, y: b)
            draw(&ctx, CGSize(width: canvasSize.width - 2 * b, height: canvasSize.height - 2 * b))
        }
        .padding(-b)
    }
}
