import SwiftUI

/// DESIGN §3.12 toast, placed in the Processes toolbar spacer: `body12` `textSecondary` ("{name} quit.",
/// "{name} was force quit."), optionally followed by an "Undo" link. The page removes it after 4 s
/// (`TTToast.lifetime`); it fades in/out with `.transition(.opacity)`.
/// Storage variant (§3.17): `init(_:actions:)` renders `small secondary` buttons after the text.
public struct TTToast: View {
    /// A toast button. Order on screen = order passed to `init(_:actions:)`.
    public enum Action {
        case show(() -> Void)
        case emptyTrash(() -> Void)
        case undo(() -> Void)

        var title: String {
            switch self {
            case .show: "Show"
            case .emptyTrash: "Empty Trash"
            case .undo: "Undo"
            }
        }

        var run: () -> Void {
            switch self {
            case .show(let f), .emptyTrash(let f), .undo(let f): f
            }
        }

        var isUndo: Bool { if case .undo = self { true } else { false } }
    }

    let text: String
    let undo: (() -> Void)?
    let actions: [Action]

    public static let lifetime: Duration = .seconds(4)
    /// Lifetime when the toast offers Undo (DESIGN §3.12, Storage variant).
    public static let undoLifetime: Duration = .seconds(10)

    public static func lifetime(hasUndo: Bool) -> Duration { hasUndo ? undoLifetime : lifetime }

    public init(_ text: String, undo: (() -> Void)? = nil) {
        self.text = text
        self.undo = undo
        self.actions = []
    }

    /// Which actions to pass is the caller's rule, not the toast's: `Show` only when the clean skipped items,
    /// `Empty Trash` only when bytes were moved to the Trash, `Undo` only for trashed items of the latest clean.
    /// Pinning the toast while Show's sheet is open is likewise the caller's timer (see `lifetime(hasUndo:)`).
    public init(_ text: String, actions: [Action]) {
        self.text = text
        self.undo = nil
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: TTSpace.x8) {
            Text(text)
                .font(TTFont.body12)
                .foregroundStyle(TTColor.textSecondary)
                .lineLimit(1)
            if let undo { TTLink("Undo", action: undo) }
            ForEach(actions.indices, id: \.self) { i in
                Button(actions[i].title, action: actions[i].run).buttonStyle(.tt(.smallSecondary))
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: actions.isEmpty ? .combine : .contain)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
