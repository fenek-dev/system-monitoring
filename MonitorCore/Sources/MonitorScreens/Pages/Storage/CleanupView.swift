import MonitorUIKit
import SwiftUI

/// Stub so W4a can reference the Cleanup view; filled by W4b.
struct CleanupView: View {
    let compact: Bool

    var body: some View {
        TTEmptyState(.empty("Cleanup"))
    }
}

/// Stub for the clean-result toast host; filled by W4b.
struct CleanToastHost: View {
    var body: some View {
        EmptyView()
    }
}
