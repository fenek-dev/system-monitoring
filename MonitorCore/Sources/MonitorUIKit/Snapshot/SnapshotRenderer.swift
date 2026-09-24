import CoreGraphics
import Foundation
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

/// MonitorUIKit (no Testing import; used by telltale-render too).
@MainActor public enum SnapshotRenderer {
    public enum Path: Sendable { case imageRenderer, hosting }

    public static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, path: Path = .hosting) -> CGImage? { nil }
    /// Pure SwiftUI only.
    public static func imageRenderer<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage? { nil }
    /// Offscreen NSWindow.
    public static func hosting<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage? { nil }
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        throw CocoaError(.featureUnsupported)
    }
}
