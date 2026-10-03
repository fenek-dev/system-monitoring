import SwiftUI

/// The popover panel's chrome (DESIGN §3.1 "Container"): 360 wide, bg `bgPopover`, 1-pt `borderPopover`,
/// radius 12, padding 6. `PopoverRoot` (W5a) is the content only. The app's `NSPanel` adds the native window
/// shadow; renders (`drawsShadow`) draw `shadowPopover` themselves.
public struct PopoverContainer<Content: View>: View {
    private let content: Content
    private let drawsShadow: Bool
    private let width: CGFloat

    /// `width` nil = the popover's 360.
    public init(drawsShadow: Bool = true, width: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.drawsShadow = drawsShadow
        self.width = width ?? ShellStyle.popoverWidth
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .padding(6)
            .frame(width: width)
            .background(shape.fill(ShellStyle.bgPopover))
            .overlay(shape.strokeBorder(ShellStyle.borderPopover, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(drawsShadow ? 0.6 : 0), radius: 25, y: 18)
    }
}
