import CoreGraphics

/// DESIGN §3.1 position: top edge 8 below the menu bar, centered on the status item, clamped 8 from the edges
/// of the screen's **visible** frame (Dock on a side included); height capped at the visible height − 40 (the
/// row list scrolls beyond). AppKit coordinates (y up). `content.width` must be the panel's actual laid-out
/// width; a wider panel than the visible frame is pinned to its left margin.
public enum PopoverPlacement {
    public static let margin: CGFloat = 8

    /// Height cap: visible height − 40 (never below 100).
    public static func maxHeight(_ visibleFrame: CGRect) -> CGFloat { max(visibleFrame.height - 40, 100) }

    public static func frame(anchor: CGRect, content: CGSize, visibleFrame: CGRect) -> CGRect {
        let h = min(content.height, maxHeight(visibleFrame))
        let w = content.width
        let top = visibleFrame.maxY - margin                             // menu bar bottom = visibleFrame top
        var x = anchor.midX - w / 2
        x = min(x, visibleFrame.maxX - margin - w)
        x = max(x, visibleFrame.minX + margin)
        return CGRect(x: x.rounded(.down), y: (top - h).rounded(), width: w, height: h)
    }

    /// Re-clamps an existing frame (after AppKit resized the panel to its content): height capped like `frame`,
    /// horizontally inside the margins, the top edge pinned 8 below the menu bar (the popover hangs from it), and
    /// never below the visible bottom. y is derived from the top.
    public static func clamp(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        var f = frame
        f.size.height = min(f.height, maxHeight(visibleFrame))
        f.origin.x = min(f.origin.x, visibleFrame.maxX - margin - f.width)
        f.origin.x = max(f.origin.x, visibleFrame.minX + margin)
        let top = visibleFrame.maxY - margin
        f.origin.y = max(top - f.height, visibleFrame.minY)
        return f
    }
}
