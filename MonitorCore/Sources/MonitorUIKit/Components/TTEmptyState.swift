import Foundation
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct TTEmptyState: View {
    public enum Kind { case collecting(since: Date?), unavailable(String), empty(String), paused }

    public init(_ kind: Kind) {}

    public var body: some View { EmptyView() }
}
