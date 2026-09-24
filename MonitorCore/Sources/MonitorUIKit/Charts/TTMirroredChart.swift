import MonitorModel
import SwiftUI

/// DESIGN §2.8 mirrored chart: VStack (no gap) of the `up` area growing upward (0…`upScale`), a 1-pt divider
/// (white @ 0.18), and the `down` area hanging from the divider (0…`downScale`). Halves share the height equally
/// (Network 90 each, Disk 80). Each half has a faint midline (artboards). Fill defaults: 0.30 up / 0.25 down,
/// line 1.5.
public struct TTMirroredChart: View, Equatable {
    let up: ChartSeries
    let down: ChartSeries
    let upScale: Double
    let downScale: Double

    public init(up: ChartSeries, down: ChartSeries, upScale: Double, downScale: Double) {
        self.up = up
        self.down = down
        self.upScale = upScale
        self.downScale = downScale
    }

    public var body: some View {
        VStack(spacing: 0) {
            TTAreaChart(up.points, color: up.color, yDomain: 0...max(upScale, .leastNonzeroMagnitude),
                        fillOpacity: up.fillOpacity ?? TTChartFill.netDown, lineWidth: up.lineWidth ?? TTStroke.spark,
                        grid: 2, showsCollecting: false)
            TTColor.chartDivider.frame(height: TTStroke.hairline)
            TTAreaChart(down.points, color: down.color, yDomain: 0...max(downScale, .leastNonzeroMagnitude),
                        fillOpacity: down.fillOpacity ?? TTChartFill.netUp, lineWidth: down.lineWidth ?? TTStroke.spark,
                        flipped: true, grid: 2, showsCollecting: false)
        }
        .overlay {
            if ChartSegments.sampleCount(up.points) < 2 && ChartSegments.sampleCount(down.points) < 2 {
                TTEmptyState(.collecting(since: nil))
            }
        }
    }
}
