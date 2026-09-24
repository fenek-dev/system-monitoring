import CoreGraphics

/// DESIGN §3.1 position: top edge 8 below the menu bar, centered on the status item, clamped 8 from the edges
/// of the screen's **visible** frame (Dock on a side included); height capped at the visible height − 40 (the
/// row list scrolls beyond). AppKit coordinates (y up). `content.width` must be the panel's actual laid-out
/// width; a wider panel than the visible frame is pinned to its left margin.
public enum PopoverPlacement {
    public static let margin: CGFloat = 8

    public static func frame(anchor: CGRect, content: CGSize, visibleFrame: CGRect) -> CGRect {
        let h = min(content.height, max(visibleFrame.height - 40, 100))
        let w = content.width
        let top = visibleFrame.maxY - margin                             // menu bar bottom = visibleFrame top
        var x = anchor.midX - w / 2
        x = min(x, visibleFrame.maxX - margin - w)
        x = max(x, visibleFrame.minX + margin)
        return CGRect(x: x.rounded(.down), y: (top - h).rounded(), width: w, height: h)
    }

    /// Re-clamps an existing frame (after AppKit resized the panel to its content) without moving the top edge.
    public static func clamp(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(f.origin.x, visibleFrame.maxX - margin - f.width)
        f.origin.x = max(f.origin.x, visibleFrame.minX + margin)
        if f.maxY > visibleFrame.maxY - margin { f.origin.y = visibleFrame.maxY - margin - f.height }
        return f
    }
}
