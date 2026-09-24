import MonitorModel
import SwiftUI

/// DESIGN §2.10 utilization area/line (0.25 fill, 1.5 line) with a dashed overlay on its own scale
/// (GPU frequency: `gpuAlt` 1.25 @ 0.7, dash [3, 3]; domain 0…max MHz). Page gridlines at quarters.
public struct TTDualChart: View, Equatable {
    let solid: ChartSeries
    let dashed: ChartSeries
    let yDomain: ClosedRange<Double>
    let dashedDomain: ClosedRange<Double>

    public init(solid: ChartSeries, dashed: ChartSeries, yDomain: ClosedRange<Double>) {
        self.init(solid: solid, dashed: dashed, yDomain: yDomain, dashedDomain: nil)
    }

    /// `dashedDomain` nil → 0…max of the dashed series.
    public init(solid: ChartSeries, dashed: ChartSeries, yDomain: ClosedRange<Double>, dashedDomain: ClosedRange<Double>?) {
        self.solid = solid
        self.dashed = dashed
        self.yDomain = yDomain
        let maxDashed = dashed.points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 1
        self.dashedDomain = dashedDomain ?? 0...max(maxDashed, 1)
    }

    public var body: some View {
        ZStack {
            TTAreaChart(solid.points, color: solid.color, yDomain: yDomain,
                        fillOpacity: solid.fillOpacity ?? TTChartFill.gpuUtilization,
                        lineWidth: solid.lineWidth ?? TTStroke.spark, grid: 4)
            TTAreaChart(dashed.points,
                        color: dashed.color.opacity(dashed.lineOpacity == 1 ? TTChartFill.gpuFrequency : dashed.lineOpacity),
                        yDomain: dashedDomain, lineOnly: true, lineWidth: dashed.lineWidth ?? TTStroke.sparkThin,
                        dash: dashed.dash.isEmpty ? TTChartFill.gpuFrequencyDash : dashed.dash, showsCollecting: false)
        }
    }
}
