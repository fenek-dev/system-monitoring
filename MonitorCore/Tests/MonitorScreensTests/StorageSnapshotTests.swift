import MonitorMocks
@testable import MonitorScreens
import Testing

/// DESIGN §3.17 Storage goldens (`__Snapshots__/storage-*.png`): each state at 1280×860 and 1100×720.
/// Bug caught: wrong state per fixture, header clipped at 1100, wall-clock text in the scanning states.
@MainActor
@Suite("StorageSnapshotTests")
struct StorageSnapshotTests {
    @Test(arguments: [
        "storage", "storage-1100", "storage-scanning", "storage-scanning-1100", "storage-map", "storage-map-1100",
        "storage-cleanup", "storage-cleanup-1100", "storage-nofda", "storage-nofda-1100",
    ])
    func screen(_ id: String) { assertScreen(id, scenario: .calm) }
}
