import SwiftUI

/// DESIGN §2.14 button variants. States (ADDED): hover secondary → `fillButtonHover`, primary/destructive
/// brightness +0.06; pressed opacity 0.8; disabled opacity 0.40 with no hover.
public struct TTButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        case smallSecondary, smallDestructive, smallPrimary
        case regularSecondary, regularDestructive
        case popoverPrimary, popoverSecondary
        case chip
    }

    let variant: Variant

    public init(_ variant: Variant) { self.variant = variant }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, variant: variant)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var height: CGFloat {
            switch variant {
            case .smallSecondary, .smallDestructive, .smallPrimary: 24
            case .regularSecondary, .regularDestructive: 28
            case .popoverPrimary, .popoverSecondary: 30
            case .chip: 22
            }
        }

        var horizontalPadding: CGFloat {
            switch variant {
            case .smallSecondary, .smallDestructive, .smallPrimary: 10
            case .regularSecondary, .regularDestructive, .popoverPrimary, .popoverSecondary: 12
            case .chip: 8
            }
        }

        var radius: CGFloat {
            switch variant {
            case .popoverPrimary, .popoverSecondary: TTRadius.r7
            case .chip: TTRadius.pill
            default: TTRadius.r6
            }
        }

        var font: Font {
            switch variant {
            case .smallSecondary, .smallDestructive, .smallPrimary: TTFont.button12
            case .chip: TTFont.caption
            default: TTFont.button13
            }
        }

        var hover: Bool { hovering && isEnabled }

        var fill: Color {
            switch variant {
            case .smallSecondary, .regularSecondary, .popoverSecondary: hover ? TTColor.fillButtonHover : TTColor.fillButton
            case .smallDestructive, .regularDestructive: TTColor.destructive
            case .smallPrimary, .popoverPrimary: TTColor.accent
            case .chip: TTColor.bgElevated
            }
        }

        var border: Color? {
            switch variant {
            case .smallSecondary, .regularSecondary: TTColor.borderControl
            case .smallDestructive, .regularDestructive: TTColor.destructive
            case .smallPrimary: TTColor.accent
            case .chip: TTColor.borderPopover
            case .popoverPrimary, .popoverSecondary: nil
            }
        }

        var textColor: Color {
            switch variant {
            case .smallSecondary, .regularSecondary, .popoverSecondary, .chip: TTColor.textPrimary
            default: TTColor.textOnAccent
            }
        }

        var brightens: Bool {
            switch variant {
            case .smallDestructive, .regularDestructive, .smallPrimary, .popoverPrimary: hover
            default: false
            }
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(font)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, variant == .popoverPrimary ? 0 : horizontalPadding)
                .frame(maxWidth: variant == .popoverPrimary ? .infinity : nil)
                .frame(height: height)
                .background(shape.fill(fill))
                .overlay { if let border { shape.strokeBorder(border, lineWidth: TTStroke.hairline) } }
                .brightness(brightens ? 0.06 : 0)
                .opacity(!isEnabled ? TTOpacity.disabled : (configuration.isPressed ? TTOpacity.pressed : 1))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

public extension ButtonStyle where Self == TTButtonStyle {
    static func tt(_ variant: TTButtonStyle.Variant) -> TTButtonStyle { TTButtonStyle(variant) }
}

/// DESIGN §2.14 icon buttons: `iconButton` 26 (popover) / 28 (header), transparent, glyph 16 `textSecondary`,
/// hover `fillIconButton`; `filled` (26, glyph 14, `fillIconButton`); `rowAction` (24, radius 5, ellipsis 16);
/// `footer` (30, radius 7, `fillButton`). Always has a tooltip + accessibility label.
/// `tint` (ADDED, overlay toggle): an "on" state — glyph in `tint`, fill `tint` at 18 %.
public struct TTIconButton: View {
    public enum Variant: Sendable { case popover, header, filled, rowAction, footer }

    let icon: TTIconName
    let label: String
    let variant: Variant
    let tint: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public init(_ icon: TTIconName, label: String, variant: Variant = .header, tint: Color? = nil,
                action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.variant = variant
        self.tint = tint
        self.action = action
    }

    var side: CGFloat {
        switch variant {
        case .popover, .filled: 26
        case .header: 28
        case .rowAction: 24
        case .footer: 30
        }
    }

    var radius: CGFloat {
        switch variant {
        case .rowAction: TTRadius.r5
        case .footer: TTRadius.r7
        default: TTRadius.r6
        }
    }

    var fill: Color {
        if let tint { return tint.opacity(0.18) }
        return switch variant {
        case .filled: TTColor.fillIconButton
        case .footer: hovering && isEnabled ? TTColor.fillButtonHover : TTColor.fillButton
        default: hovering && isEnabled ? TTColor.fillIconButton : .clear
        }
    }

    public var body: some View {
        Button(action: action) {
            TTIcon(icon, size: variant == .filled ? 14 : 16, color: tint ?? TTColor.textSecondary)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressOpacityStyle())
        .opacity(isEnabled ? 1 : TTOpacity.disabled)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PressOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? TTOpacity.pressed : 1)
    }
}

/// DESIGN §2.14 `link`: `body12` in `link`, hover `linkHover`, no underline.
public struct TTLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title).font(TTFont.body12).foregroundStyle(hovering ? TTColor.linkHover : TTColor.link).lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
