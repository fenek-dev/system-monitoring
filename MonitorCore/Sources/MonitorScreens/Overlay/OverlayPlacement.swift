import CoreGraphics

/// Where the overlay panel goes (spec 2026-09-25 overlay §Window). Pure: AppKit passes `NSScreen` frames in
/// global, bottom-left-origin coordinates.
public enum OverlayPlacement {
    /// Frame for content of `size` in `visibleFrame`, with an 8-pt inset from the edges.
    /// `visibleFrame` already excludes the menu bar and notch, so "top" sits `inset` below it.
    public static func frame(size: CGSize, visibleFrame: CGRect, corner: OverlayCorner, inset: CGFloat = 8) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft, .bottomLeft: x = visibleFrame.minX + inset
        case .topRight, .bottomRight: x = visibleFrame.maxX - inset - size.width
        }
        switch corner {
        case .topLeft, .topRight: y = visibleFrame.maxY - inset - size.height
        case .bottomLeft, .bottomRight: y = visibleFrame.minY + inset
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Index of the screen whose frame contains `mouse`, else `mainIndex`.
    /// Containment matches `NSMouseInRect(_, _, false)`: minX and maxY are inside, maxX and minY are not.
    public static func screenIndex(mouse: CGPoint, screenFrames: [CGRect], mainIndex: Int) -> Int {
        screenFrames.firstIndex { f in
            mouse.x >= f.minX && mouse.x < f.maxX && mouse.y > f.minY && mouse.y <= f.maxY
        } ?? mainIndex
    }
}
