import SwiftUI

/// One signature everywhere (ARCHITECTURE §6, DESIGN §3.15):
/// - nil (or "—") → "—" in `textTertiary`, same font, `.help(reason)` when a reason is given;
/// - `estimated` → same style, `.help("Estimated")` (DESIGN §3.10), announced as "estimated";
/// - otherwise the text in the inherited foreground style, tabular digits, one line.
public struct MetricValue: View, Equatable {
    private let text: String?
    private let unavailableReason: String?
    private let estimated: Bool
    private let font: Font

    public init(_ text: String?, unavailableReason: String? = nil, estimated: Bool = false, font: Font = TTFont.body13) {
        self.text = text
        self.unavailableReason = unavailableReason
        self.estimated = estimated
        self.font = font
    }

    /// What the value presents: displayed text, tooltip (nil = none), accessibility label.
    struct Presentation: Equatable {
        var text: String
        var unavailable: Bool
        var tooltip: String?
        var accessibilityLabel: String
    }

    nonisolated static func presentation(_ text: String?, unavailableReason: String?, estimated: Bool) -> Presentation {
        guard let text, text != TTFormat.unavailable else {
            return Presentation(text: TTFormat.unavailable, unavailable: true, tooltip: unavailableReason,
                                accessibilityLabel: unavailableReason.map { "Unavailable, \($0)" } ?? "Unavailable")
        }
        return Presentation(text: text, unavailable: false, tooltip: estimated ? "Estimated" : nil,
                            accessibilityLabel: estimated ? "\(text), estimated" : text)
    }

    public var body: some View {
        let p = Self.presentation(text, unavailableReason: unavailableReason, estimated: estimated)
        Text(p.text)
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
            .modifier(UnavailableStyle(active: p.unavailable)) // available values inherit the caller's style
            .modifier(OptionalHelp(text: p.tooltip))
            .accessibilityLabel(p.accessibilityLabel)
    }
}

struct UnavailableStyle: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.foregroundStyle(TTColor.textTertiary) } else { content }
    }
}

/// `.help` only when there is a tooltip (no empty help tags), and only in an active table row (`\.ttRowActive`:
/// hovered/selected; always true outside tables).
struct OptionalHelp: ViewModifier {
    let text: String?
    @Environment(\.ttRowActive) private var active
    func body(content: Content) -> some View {
        if let text, active { content.help(text) } else { content }
    }
}
