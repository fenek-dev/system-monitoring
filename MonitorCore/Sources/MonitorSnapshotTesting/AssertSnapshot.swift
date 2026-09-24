import CoreGraphics
import MonitorUIKit
import SwiftUI
import Testing

// W0b stub (ARCHITECTURE §5.12). W3 replaces this file. Records an issue so no test passes against the stub.

@MainActor public func assertSnapshot<V: View>(_ view: V, size: CGSize, named: String, path: SnapshotRenderer.Path = .hosting,
                                               tolerance: Double = 0.005, sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record("assertSnapshot not implemented (W0b stub): \(named)", sourceLocation: sourceLocation)
}
