import MonitorModel
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct ChartSeries: Identifiable {
    public var id: String
    public var label: String
    public var color: Color
    public var points: [SeriesPoint]

    public init(id: String, label: String, color: Color, points: [SeriesPoint]) {
        self.id = id
        self.label = label
        self.color = color
        self.points = points
    }
}
