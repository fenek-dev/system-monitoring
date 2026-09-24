import MonitorModel
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct TTMetricTile: View {
    public init(category: MonitorModel.Category, value: String?, unit: String?, detail: String?, points: [SeriesPoint],
                unavailableReason: String?) {}

    public var body: some View { EmptyView() }
}
