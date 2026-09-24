import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

/// One signature everywhere (§6): nil text → "—" + tooltip; estimated → DESIGN "estimated" style + tooltip.
public struct MetricValue: View {
    private let text: String?
    private let font: Font

    public init(_ text: String?, unavailableReason: String? = nil, estimated: Bool = false, font: Font = TTFont.body13) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text ?? "—").font(font)
    }
}
