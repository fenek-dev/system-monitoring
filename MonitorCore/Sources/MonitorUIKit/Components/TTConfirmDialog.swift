import SwiftUI

/// DESIGN §2.26 modal confirm dialog, drawn as an overlay filling the window content (sidebar included):
/// `bgScrim` scrim; dialog 380 wide, horizontally centered, top at y = 52; `bgElevated`, 1-pt `borderPopover`,
/// radius 12, `shadowDialog`, padding 20, VStack gap 12: title `dialogTitle`, body `body12Para` `textSecondary`,
/// right-aligned buttons (gap 8, 4 top padding): [Cancel (regular secondary)] [confirm (regular destructive)].
/// Esc = Cancel; no default button. Present with `.transition(TTConfirmDialog.transition)` (opacity + scale
/// 0.97→1, 0.15 s). Clicking the scrim does nothing (modal).
/// The content under the scrim must also be disabled (keyboard/VoiceOver): use `.ttConfirmDialog(_:)` on the window
/// content, which does both.
public struct TTConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public static var transition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: 0.15))
    }

    public var body: some View {
        ZStack(alignment: .top) {
            TTColor.bgScrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            dialog
                .padding(.top, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: onCancel)
        .accessibilityAddTraits(.isModal)
    }

    private var dialog: some View {
        let shape = RoundedRectangle(cornerRadius: TTRadius.window, style: .continuous)
        return VStack(alignment: .leading, spacing: TTSpace.x12) {
            Text(title)
                .font(TTFont.dialogTitle)
                .foregroundStyle(TTColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(TTFont.body12Para)
                .lineSpacing(TTFont.body12ParaSpacing)
                .foregroundStyle(TTColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TTSpace.x8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.tt(.regularSecondary))
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .buttonStyle(.tt(.regularDestructive))
            }
            .padding(.top, TTSpace.x4)
        }
        .padding(TTSpace.x20 + TTStroke.hairline)
        .frame(width: 380, alignment: .leading)
        .background(shape.fill(TTColor.bgElevated))
        .overlay(shape.strokeBorder(TTColor.borderPopover, lineWidth: TTStroke.hairline))
        .shadow(color: .black.opacity(TTShadow.dialog.opacity), radius: TTShadow.dialog.radius, y: TTShadow.dialog.y)
    }
}

public extension View {
    /// Presents `dialog` (when non-nil) over this content with the scrim, disabling the content underneath
    /// (no clicks, keys or VoiceOver focus behind the modal) and animating per `TTConfirmDialog.transition`.
    func ttConfirmDialog(_ dialog: TTConfirmDialog?) -> some View {
        self
            .disabled(dialog != nil)
            .accessibilityHidden(dialog != nil)
            .overlay {
                if let dialog { dialog.transition(TTConfirmDialog.transition) }
            }
    }
}
