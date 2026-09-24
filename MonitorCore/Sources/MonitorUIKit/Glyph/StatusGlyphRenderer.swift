import AppKit
import MonitorModel

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

@MainActor public enum StatusGlyphRenderer {
    public static func image(for state: AlertState, pointSize: CGFloat = 18) -> NSImage {
        NSImage(size: NSSize(width: pointSize, height: pointSize))
    }
}
