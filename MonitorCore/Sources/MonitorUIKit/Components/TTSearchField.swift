import SwiftUI

/// DESIGN §2.27 search field: height 28, width 220, padding 8, radius 7, `fillField`; HStack gap 6 of the `search`
/// icon 14 and a plain text field (`body12`, `textPrimary`, placeholder `textSecondary`). No focus ring; caret
/// `accent`. Esc clears.
public struct TTSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let width: CGFloat

    public init(text: Binding<String>, prompt: String) {
        self.init(text: text, prompt: prompt, width: 220)
    }

    public init(text: Binding<String>, prompt: String, width: CGFloat) {
        _text = text
        self.prompt = prompt
        self.width = width
    }

    public var body: some View {
        HStack(spacing: TTSpace.x6) {
            TTIcon(.search, size: 14, color: TTColor.textSecondary)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(TTColor.textSecondary))
                .textFieldStyle(.plain)
                .font(TTFont.body12)
                .foregroundStyle(TTColor.textPrimary)
                .tint(TTColor.accent)
                .focusEffectDisabled()
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
        }
        .padding(.horizontal, TTSpace.x8)
        .frame(width: width, height: 28)
        .background(RoundedRectangle(cornerRadius: TTRadius.r7, style: .continuous).fill(TTColor.fillField))
    }
}
