import SwiftUI

/// DESIGN §2.1: `bgCard`, 1-pt `borderCard`, radius 10, padding 16; content is a leading VStack with a per-card gap
/// (12 default, 10 chart cards, 8 table cards, 6 ANE/sensors).
public struct TTCard<Content: View>: View {
    private let padding: CGFloat
    private let spacing: CGFloat
    private let content: Content

    public init(padding: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.init(padding: padding, spacing: nil, content: content)
    }

    public init(padding: CGFloat? = nil, spacing: CGFloat?, @ViewBuilder content: () -> Content) {
        self.padding = padding ?? TTSpace.cardPadding
        self.spacing = spacing ?? TTSpace.gridGap
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            // CSS content-box: the 1-pt border sits outside the padding.
            .padding(padding + TTStroke.hairline)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .ttCardBackground()
    }
}

public extension View {
    /// Card surface: `bgCard` + 1-pt inner `borderCard`, radius 10.
    func ttCardBackground(border: Color = TTColor.borderCard) -> some View {
        background(
            RoundedRectangle(cornerRadius: TTRadius.card, style: .continuous)
                .fill(TTColor.bgCard)
                .strokeBorder(border, lineWidth: TTStroke.hairline)
        )
    }
}

/// DESIGN §2.1 card header: HStack gap 8, min-height 20; optional 16-pt icon, `sectionTitle` (flex), trailing.
/// `icon` is a `TTIconName` raw value ("cpu", "power", …).
public struct TTCardHeader<Trailing: View>: View {
    private let title: String
    private let icon: TTIconName?
    private let trailing: Trailing

    public init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon.flatMap(TTIconName.init(rawValue:))
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: TTSpace.x8) {
            if let icon { TTIcon(icon, size: 16) }
            Text(title)
                .font(TTFont.sectionTitle)
                .foregroundStyle(TTColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(minHeight: 20)
    }
}

public extension TTCardHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil) {
        self.init(title, icon: icon) { EmptyView() }
    }
}

/// Header trailing caption (`body12`, `textSecondary`).
public struct TTCaption: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).monospacedDigit().lineLimit(1)
    }
}
