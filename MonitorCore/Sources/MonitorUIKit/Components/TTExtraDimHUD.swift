import SwiftUI

/// Extra-dim HUD (extra-dim spec §6): `sun.min` glyph, 8 segments (filled = active dim steps, `textPrimary` on
/// `fillTrack`), "Extra dim" + "n/8". Variants replace the level with a message. Popover chrome: `bgPopover`,
/// 1-pt `borderPopover`, card radius, `shadowPopover`, padding 16. Fixed width so a panel can size to fit.
public struct TTExtraDimHUD: View {
    public enum Content: Equatable, Sendable { case level(Int), resetByOtherApp, cannotDim }

    public static let steps = 8
    public static let width: CGFloat = 240

    let content: Content

    public init(_ content: Content) { self.content = content }

    private var level: Int? {
        if case .level(let n) = content { return min(max(n, 0), Self.steps) }
        return nil
    }

    private var message: String? {
        switch content {
        case .level: nil
        case .resetByOtherApp: "Dimming reset by another app"
        case .cannotDim: "Can't dim this display"
        }
    }

    private var summary: String {
        if let level { return "Extra dim \(level) of \(Self.steps)" }
        return message ?? ""
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TTRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: TTSpace.x8) {
            HStack(spacing: TTSpace.x8) {
                Image(systemName: "sun.min")
                    .font(.system(size: 16))
                    .foregroundStyle(TTColor.textPrimary)
                if let level {
                    Text("Extra dim").font(TTFont.body12Strong).foregroundStyle(TTColor.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(level)/\(Self.steps)").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                } else if let message {
                    Text(message).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if let level {
                HStack(spacing: TTSpace.x3) {
                    ForEach(0..<Self.steps, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(i < level ? TTColor.textPrimary : TTColor.fillTrack)
                            .frame(height: 6)
                    }
                }
            }
        }
        .padding(TTSpace.cardPadding)
        .frame(width: Self.width)
        .background(shape.fill(TTColor.bgPopover))
        .overlay(shape.strokeBorder(TTColor.borderPopover, lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(TTShadow.popover.opacity), radius: TTShadow.popover.radius, y: TTShadow.popover.y)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}
