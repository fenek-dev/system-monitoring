import MonitorModel
import SwiftUI

/// DESIGN §2.3 sparkline / area chart, drawn with `Canvas` (ARCHITECTURE §7).
/// Area (series color @ `fillOpacity`) then line (`lineWidth`, butt caps, round joins); x even over N samples,
/// y clamped to `yDomain`; gaps break line and area; the line may bleed 1 pt past the frame.
/// Fewer than 2 samples → "Collecting…" (DESIGN §3.15).
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
    let showsCollecting: Bool

    /// - Parameters:
    ///   - fillOpacity: area opacity applied to `color` (DESIGN §1.1 "Chart series fills", e.g. 0.22).
    ///   - flipped: area hangs down from the top edge (mirrored chart bottom half).
    public init(_ points: [SeriesPoint], color: Color, yDomain: ClosedRange<Double>, fillOpacity: Double = 1,
                lineOnly: Bool = false, lineWidth: CGFloat = TTStroke.spark, flipped: Bool = false, dash: [CGFloat] = [],
                showsCollecting: Bool = true) {
        self.points = points
        self.color = color
        self.yDomain = yDomain
        self.fillOpacity = fillOpacity
        self.lineOnly = lineOnly
        self.lineWidth = lineWidth
        self.flipped = flipped
        self.dash = dash
        self.showsCollecting = showsCollecting
    }

    /// Room around the frame so the line can bleed past it.
    static let bleed: CGFloat = 2

    public var body: some View {
        if showsCollecting && ChartSegments.sampleCount(points) < 2 {
            TTEmptyState(.collecting(since: nil))
        } else {
            let points = points, color = color, domain = yDomain, fill = fillOpacity, lineOnly = lineOnly
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round, dash: dash)
            let flipped = flipped
            Canvas(rendersAsynchronously: false) { ctx, canvasSize in
                let b = Self.bleed
                let size = CGSize(width: canvasSize.width - 2 * b, height: canvasSize.height - 2 * b)
                ctx.translateBy(x: b, y: b)
                let drawn = points.count > Int(size.width * 2)
                    ? ChartSegments.decimate(points, maxPoints: max(2, Int(size.width * 2)))
                    : points
                var line = Path()
                var area: Path? = lineOnly ? nil : Path()
                ChartSegments.addSeries(drawn, domain: domain, in: size, line: &line, area: &area, flipped: flipped)
                if let area { ctx.fill(area, with: .color(color.opacity(fill))) }
                ctx.stroke(line, with: .color(color), style: style)
            }
            .padding(-Self.bleed)
            .accessibilityHidden(true)
        }
    }
}
