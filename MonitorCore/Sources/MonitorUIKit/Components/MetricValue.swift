import SwiftUI

/// One signature everywhere (ARCHITECTURE §6, DESIGN §3.15):
/// - nil (or "—") → "—" in `textTertiary`, same font, `.help(reason)` when a reason is given;
/// - `estimated` → same style, `.help("Estimated")` (DESIGN §3.10);
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

    private var isUnavailable: Bool { text == nil || text == TTFormat.unavailable }

    public var body: some View {
        if isUnavailable {
            Text(TTFormat.unavailable)
                .font(font)
                .foregroundStyle(TTColor.textTertiary)
                .lineLimit(1)
                .help(unavailableReason ?? "")
                .accessibilityLabel(unavailableReason.map { "Unavailable, \($0)" } ?? "Unavailable")
        } else {
            Text(text ?? "")
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .help(estimated ? "Estimated" : "")
        }
    }
}
