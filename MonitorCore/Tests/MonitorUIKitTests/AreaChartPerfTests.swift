import Foundation
import MonitorModel
import SwiftUI
import Testing
@testable import MonitorUIKit

/// Advisory perf gate (plan W3 verification): 7 area charts × 60 points, 100 offscreen renders; reports ms/frame
/// (budget < 4 ms advisory — reported, not enforced).
@MainActor @Suite struct AreaChartPerfTests {
    struct Seven: View {
        let series: [[SeriesPoint]]
        var body: some View {
            VStack(spacing: 4) {
                ForEach(series.indices, id: \.self) { i in
                    TTAreaChart(series[i], color: TTColor.cpu, yDomain: 0...1, fillOpacity: TTChartFill.sparkline,
                                lineWidth: TTStroke.sparkThin)
                        .frame(width: 480, height: 30)
                }
            }
        }
    }

    @Test func sevenChartsSixtyPoints() {
        let base = (0..<7).map { SampleSeries.wave(base: 0.4, amplitude: 0.2, seed: $0) }
        // Warm-up.
        _ = SnapshotRenderer.imageRenderer(Seven(series: base), size: CGSize(width: 480, height: 240), scale: 2)
        let clock = ContinuousClock()
        let frames = 100
        let elapsed = clock.measure {
            for f in 0..<frames {
                // Shift data each frame, as a live tick would.
                let shifted = base.map { s in Array(s.dropFirst(f % 5)) + Array(s.prefix(f % 5)) }
                _ = SnapshotRenderer.imageRenderer(Seven(series: shifted), size: CGSize(width: 480, height: 240), scale: 2)
            }
        }
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("AreaChartPerf: \(String(format: "%.2f", ms / Double(frames))) ms/frame (7 charts × 60 pts, offscreen @2x incl. rasterization; advisory < 4 ms)")
    }
}
