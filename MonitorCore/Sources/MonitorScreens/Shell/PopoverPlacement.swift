import CoreGraphics

/// DESIGN §3.1 position: top edge 8 below the menu bar, centered on the status item, clamped 8 from the
/// screen edges; height capped at the visible height − 40 (the row list scrolls beyond). AppKit coordinates
/// (y up).
public enum PopoverPlacement {
    public static func frame(anchor: CGRect, content: CGSize, visibleFrame: CGRect, screenFrame: CGRect) -> CGRect {
        let h = min(content.height, max(visibleFrame.height - 40, 100))
        let w = content.width
        let top = visibleFrame.maxY - 8                                  // menu bar bottom = visibleFrame top
        var x = anchor.midX - w / 2
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - 8 - w)
        return CGRect(x: x.rounded(), y: (top - h).rounded(), width: w, height: h)
    }
}
