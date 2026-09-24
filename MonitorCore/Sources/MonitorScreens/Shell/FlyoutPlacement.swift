import CoreGraphics

/// DESIGN §2.22 flyout position, AppKit coordinates (y up): beside the popover on its LEFT (the popover hangs from
/// the top-right menu bar), `gap` from its edge; on the RIGHT when the left side has no room inside the visible
/// frame's 8-pt margin. Top edge aligned with the hovered row's top, then clamped vertically inside the margins;
/// height capped at the visible height − 16.
public enum FlyoutPlacement {
    public static let margin = PopoverPlacement.margin

    public static func frame(rowRect: CGRect, popoverFrame: CGRect, visibleFrame: CGRect, size: CGSize,
                             gap: CGFloat = 6) -> CGRect {
        let h = min(size.height, max(visibleFrame.height - 2 * margin, 0))
        let w = size.width
        let left = popoverFrame.minX - gap - w
        let right = popoverFrame.maxX + gap
        var x: CGFloat
        if left >= visibleFrame.minX + margin {
            x = left
        } else if right + w <= visibleFrame.maxX - margin {
            x = right
        } else {
            x = visibleFrame.minX + margin      // no room on either side: overlap the popover at the left margin
        }
        x = x.rounded(.down)
        var top = rowRect.maxY
        top = min(top, visibleFrame.maxY - margin)
        top = max(top, visibleFrame.minY + margin + h)
        return CGRect(x: x, y: (top - h).rounded(), width: w, height: h)
    }
}
