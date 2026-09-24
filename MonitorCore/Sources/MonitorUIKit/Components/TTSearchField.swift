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
            // The macOS TextField ignores the prompt's foreground style (it drew near-white), so the placeholder is
            // an overlay in `textSecondary` #A8A8B0 (DESIGN §2.27), shown while the field is empty.
            TextField("", text: $text)
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text(prompt).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(prompt)
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
