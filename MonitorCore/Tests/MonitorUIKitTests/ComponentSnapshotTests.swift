import MonitorSnapshotTesting
import SwiftUI
import Testing
@testable import MonitorUIKit

/// Goldens of the gallery items, recorded after a visual check against the reference artboards
/// (see the W3 report for the side-by-side notes).
@MainActor @Suite struct ComponentSnapshotTests {
    nonisolated static let ids = ["icons", "metric-tiles", "stat-strip", "controls", "bars", "key-value", "states",
                                  "timeline-card", "cpu-usage", "net-throughput", "thermal-lines", "gpu-dual",
                                  "processes-list", "search-field", "core-bars", "fan-gauges", "treemap", "row-action", "tile-states", "alert-banner", "confirm-dialog", "toast", "top-processes"]

    @Test(arguments: ids)
    func galleryItem(id: String) throws {
        let item = try #require(TTGallery.item(id))
        assertSnapshot(item.make(), size: item.size, named: "component-\(id)")
    }
}
