import CoreGraphics

/// Where the clipboard picker goes (spec 2026-10-06 clipboard history, "Picker"). Pure: AppKit passes the mouse
/// position and the `NSScreen.visibleFrame` under it in global, bottom-left-origin coordinates.
public enum ClipboardPanelPlacement {
    /// The panel's top-left corner sits `offset` right of and below the mouse, then the frame is shifted to lie
    /// inside `visibleFrame`. A panel larger than `visibleFrame` is pinned to its top-left corner.
    public static func frame(mouse: CGPoint, size: CGSize, visibleFrame: CGRect, offset: CGFloat = 8) -> CGRect {
        let x = mouse.x + offset
        let y = mouse.y - offset - size.height
        // Right/bottom first, left/top last: they win when the panel does not fit.
        let fittedX = max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width))
        let fittedY = min(visibleFrame.maxY - size.height, max(y, visibleFrame.minY))
        return CGRect(origin: CGPoint(x: fittedX, y: fittedY), size: size)
    }
}
