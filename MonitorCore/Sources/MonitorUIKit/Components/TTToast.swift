import SwiftUI

/// DESIGN §3.12 toast, placed in the Processes toolbar spacer: `body12` `textSecondary` ("{name} quit.",
/// "{name} was force quit."), optionally followed by an "Undo" link. The page removes it after 4 s
/// (`TTToast.lifetime`); it fades in/out with `.transition(.opacity)`.
public struct TTToast: View {
    let text: String
    let undo: (() -> Void)?

    public static let lifetime: Duration = .seconds(4)

    public init(_ text: String, undo: (() -> Void)? = nil) {
        self.text = text
        self.undo = undo
    }

    public var body: some View {
        HStack(spacing: TTSpace.x8) {
            Text(text)
                .font(TTFont.body12)
                .foregroundStyle(TTColor.textSecondary)
                .lineLimit(1)
            if let undo { TTLink("Undo", action: undo) }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
