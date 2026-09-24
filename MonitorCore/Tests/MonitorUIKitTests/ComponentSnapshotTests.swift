import Foundation
import MonitorModel
import MonitorSnapshotTesting
import SwiftUI
import Testing
@testable import MonitorUIKit

/// Goldens of the gallery items, recorded after a visual check against the reference artboards
/// (see the W3 report for the side-by-side notes).
@MainActor @Suite struct ComponentSnapshotTests {
    nonisolated static let ids = ["icons", "metric-tiles", "stat-strip", "controls", "bars", "key-value", "states",
                                  "timeline-card", "cpu-usage", "net-throughput", "thermal-lines", "gpu-dual",
                                  "processes-list", "search-field", "core-bars", "fan-gauges", "treemap", "row-action", "tile-states", "alert-banner", "confirm-dialog", "toast", "top-processes",
                                  "popover-rows", "popover-rows-alert", "popover-expanded", "sidebar", "status-icons", "thermal-scale", "app-icons"]

    @Test(arguments: ids)
    func galleryItem(id: String) throws {
        let item = try #require(TTGallery.item(id))
        assertSnapshot(item.make(), size: item.size, named: "component-\(id)")
    }

    /// U-M6 partial history: a stored window whose first 40 % has no bucket yet → `fillTrack` + "No data yet";
    /// a loaded window with one sample → "No data yet" (not "Collecting…").
    @Test func partialHistoryChart() {
        let t0 = Date(timeIntervalSince1970: 0)
        let points = (0..<60).map { (i: Int) -> SeriesPoint in
            let v: Double? = i < 24 ? nil : 0.3 + 0.2 * sin(Double(i) / 5)
            return SeriesPoint(time: t0.addingTimeInterval(Double(i) * 60), value: v)
        }
        let one = (0..<60).map { SeriesPoint(time: t0.addingTimeInterval(Double($0) * 60), value: $0 == 59 ? 0.4 : nil) }
        let view = VStack(spacing: 12) {
            TTAreaChart(points, color: TTColor.cpu, yDomain: 0...1, fillOpacity: TTChartFill.sparkline,
                        partialHistory: true).frame(height: 60)
            TTAreaChart(one, color: TTColor.cpu, yDomain: 0...1, partialHistory: true).frame(height: 60)
        }
        .padding(12).frame(width: 480).background(TTColor.bgCard)
        assertSnapshot(view, size: CGSize(width: 480, height: 156), named: "component-partial-history")
    }
}
