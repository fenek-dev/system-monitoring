import CoreGraphics
import MonitorLive
import MonitorMocks
import MonitorModel
import SwiftUI

// W0b stub (ARCHITECTURE §5.11, §8). W4 replaces this file.

/// Screen × scenario × size, rendered by telltale-render and screen snapshot tests.
public enum ScreenCatalog {
    public struct Entry: Identifiable {
        public var id: String
        public var size: CGSize
        public var make: @MainActor (MockScenario) -> AnyView

        public init(id: String, size: CGSize, make: @escaping @MainActor (MockScenario) -> AnyView) {
            self.id = id
            self.size = size
            self.make = make
        }
    }

    @MainActor public static let entries: [Entry] = []
}

public extension LiveModel {
    @MainActor static func mock(_ scenario: MockScenario, ticks: Int = 60) -> LiveModel {
        let provider = MockDataProvider(scenario: scenario)
        let model = LiveModel(device: provider.device)
        for tick in 0..<ticks {
            model.apply(provider.frame(at: tick))
        }
        return model
    }
}
