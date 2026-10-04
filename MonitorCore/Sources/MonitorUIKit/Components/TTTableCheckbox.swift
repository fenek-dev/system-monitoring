import SwiftUI

/// DESIGN §2.29 table checkbox cell: `Toggle(.checkbox)` tinted `accent`, 16 wide inside a 24-wide column
/// (`columnWidth`), vertically centred by the row. Group rows pass `.mixed` when only some children are checked;
/// toggling reports once and the caller decides the new state (a mixed group checks all its children).
/// Disabled (no-op delete mode): `opacity.disabled` and `disabledReason` as the tooltip.
/// Place it in a `TTTable` cell; clicking the checkbox toggles it and the row's own tap (select / expand) is the
/// caller's to suppress if the control does not already consume the click. Space on the selected row goes through
/// `TTTable`'s `onSpace`.
public struct TTTableCheckbox: View {
    public enum CheckState: Equatable, Sendable { case off, on, mixed }

    public static let columnWidth: CGFloat = 24

    let state: CheckState
    let disabledReason: String?
    let toggle: () -> Void

    /// `disabledReason` non-nil disables the control and shows the reason on hover.
    public init(_ state: CheckState, disabledReason: String? = nil, toggle: @escaping () -> Void) {
        self.state = state
        self.disabledReason = disabledReason
        self.toggle = toggle
    }

    public var body: some View {
        // `Toggle(sources:)` shows the mixed look when its sources disagree; only the first source reports, so a
        // click on a mixed box calls `toggle` once, not once per source.
        let first = Binding(get: { state != .off }, set: { _ in toggle() })
        let second = Binding(get: { false }, set: { _ in })
        let sources: [Binding<Bool>] = state == .mixed ? [first, second] : [first]
        Toggle(sources: sources, isOn: \.self) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .tint(TTColor.accent)
            .frame(width: 16)
            .padding(.horizontal, (Self.columnWidth - 16) / 2)
            .disabled(disabledReason != nil)
            .opacity(disabledReason != nil ? TTOpacity.disabled : 1)
            .help(disabledReason ?? "")
            .accessibilityValue(state == .mixed ? "Mixed" : (state == .on ? "Checked" : "Unchecked"))
    }
}
