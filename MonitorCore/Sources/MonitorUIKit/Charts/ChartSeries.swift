import MonitorModel
import SwiftUI

/// One chart series. `color` is the opaque series color (legend swatches use it as is); the chart applies
/// `fillOpacity` / `lineWidth` / `lineOpacity` / `dash` (DESIGN §1.1 "Chart series fills"; see `TTChartFill`).
public struct ChartSeries: Identifiable, Equatable {
    public var id: String
    public var label: String
    public var color: Color
    public var points: [SeriesPoint]
    /// Area opacity; nil = the chart's default.
    public var fillOpacity: Double?
    /// Line width; nil = the chart's default.
    public var lineWidth: CGFloat?
    public var lineOpacity: Double
    public var dash: [CGFloat]

    public init(id: String, label: String, color: Color, points: [SeriesPoint]) {
        self.init(id: id, label: label, color: color, points: points, fillOpacity: nil)
    }

    public init(id: String, label: String, color: Color, points: [SeriesPoint], fillOpacity: Double?,
                lineWidth: CGFloat? = nil, lineOpacity: Double = 1, dash: [CGFloat] = []) {
        self.id = id
        self.label = label
        self.color = color
        self.points = points
        self.fillOpacity = fillOpacity
        self.lineWidth = lineWidth
        self.lineOpacity = lineOpacity
        self.dash = dash
    }
}

/// Faint page-chart gridlines (artboards: `rgba(255,255,255,0.06)` 1 pt at each 1/`divisions`, under the series).
public enum ChartGrid {
    public static let color = Color.white.opacity(0.06)

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, divisions: Int) {
        guard divisions > 1 else { return }
        var path = Path()
        for k in 1..<divisions {
            let y = size.height * CGFloat(k) / CGFloat(divisions) // as the SVG: centered on the exact fraction
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(path, with: .color(color), lineWidth: 1)
    }
}

/// A horizontal band behind a chart, in domain units (Memory pressure warning/critical zones).
public struct TTChartBand: Equatable, Sendable {
    public var range: ClosedRange<Double>
    public var color: Color
    public init(_ range: ClosedRange<Double>, color: Color) {
        self.range = range
        self.color = color
    }
}
