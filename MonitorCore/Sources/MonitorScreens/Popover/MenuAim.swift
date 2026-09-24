import CoreGraphics

/// Safe-triangle menu aim for the top-apps flyout (ruling): the pointer heads for the flyout when its new position
/// lies inside the triangle from its previous position to the flyout's two near corners (the edge facing the
/// pointer). Any coordinate space, as long as all inputs share it.
public enum MenuAim {
    public static func isAiming(from last: CGPoint, to point: CGPoint, flyout: CGRect) -> Bool {
        guard point != last, !flyout.isEmpty else { return false }
        let nearX = flyout.midX < last.x ? flyout.maxX : flyout.minX
        return contains(point, a: last, b: CGPoint(x: nearX, y: flyout.minY), c: CGPoint(x: nearX, y: flyout.maxY))
    }

    /// Point in triangle, edges included (sign of the three edge cross products agree).
    static func contains(_ p: CGPoint, a: CGPoint, b: CGPoint, c: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ u: CGPoint, _ v: CGPoint) -> CGFloat {
            (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
        }
        let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
        let negative = d1 < 0 || d2 < 0 || d3 < 0
        let positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }
}
