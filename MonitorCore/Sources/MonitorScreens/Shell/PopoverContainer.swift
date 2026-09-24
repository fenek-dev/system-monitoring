import SwiftUI

/// The popover panel's chrome (DESIGN §3.1 "Container"): 360 wide, bg `bgPopover`, 1-pt `borderPopover`,
/// radius 12, padding 6. `PopoverRoot` (W5a) is the content only. The app's `NSPanel` adds the native window
/// shadow; renders (`drawsShadow`) draw `shadowPopover` themselves.
public struct PopoverContainer<Content: View>: View {
    private let content: Content
    private let drawsShadow: Bool

    public init(drawsShadow: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.drawsShadow = drawsShadow
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .padding(6)
            .frame(width: ShellStyle.popoverWidth)
            .background(shape.fill(ShellStyle.bgPopover))
            .overlay(shape.strokeBorder(ShellStyle.borderPopover, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(drawsShadow ? 0.6 : 0), radius: 25, y: 18)
    }
}
