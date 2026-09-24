import MonitorModel
import SwiftUI

/// DESIGN §2.23 popover alert banner. Outer margin 2 top, 6 horizontal, 6 bottom (included); padding 10×12,
/// radius 8, `statusElevatedBannerFill` + 1-pt `statusElevatedBannerBorder` (critical: red variants).
/// VStack gap 8: `message` in `bannerText` (12, line spacing 3) `textPrimary`; HStack gap 6 of small secondary
/// buttons. `title` is not drawn (the design shows one paragraph); it leads the accessibility label.
public struct TTAlertBanner: View {
    let title: String
    let message: String
    let level: AlertLevel
    let actions: [BannerAction]

    public init(title: String, message: String, level: AlertLevel, actions: [BannerAction]) {
        self.title = title
        self.message = message
        self.level = level
        self.actions = actions
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TTRadius.r8, style: .continuous)
        VStack(alignment: .leading, spacing: TTSpace.x8) {
            Text(message)
                .font(TTFont.bannerText)
                .lineSpacing(TTFont.bannerTextSpacing)
                .foregroundStyle(TTColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(title.isEmpty ? message : "\(title). \(message)")
            if !actions.isEmpty {
                HStack(spacing: TTSpace.x6) {
                    ForEach(actions) { action in
                        Button(role: action.role) { action.perform() } label: { Text(action.title) }
                            .buttonStyle(.tt(.smallSecondary))
                    }
                }
            }
        }
        .padding(.vertical, TTSpace.x10 + TTStroke.hairline)
        .padding(.horizontal, TTSpace.x12 + TTStroke.hairline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(TTColor.bannerFill(level)))
        .overlay(shape.strokeBorder(TTColor.bannerBorder(level), lineWidth: TTStroke.hairline))
        .padding(.top, TTSpace.x2)
        .padding(.horizontal, TTSpace.x6)
        .padding(.bottom, TTSpace.x6)
        .accessibilityElement(children: .contain)
    }
}

public struct BannerAction: Identifiable {
    public var id: String
    public var title: String
    public var role: ButtonRole?
    public var perform: @MainActor () -> Void

    public init(id: String, title: String, role: ButtonRole? = nil, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.role = role
        self.perform = perform
    }
}
