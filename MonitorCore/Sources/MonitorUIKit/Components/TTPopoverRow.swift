import MonitorModel
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct TTPopoverRow: View {
    public init(category: MonitorModel.Category, subtitle: String?, value: String?, points: [SeriesPoint],
                compact: Bool, expanded: Binding<Bool>, topApps: [AppSample]) {}

    public var body: some View { EmptyView() }
}
