import CoreGraphics

/// Pointer → tile lookup over the cached layout rects of `TTSpaceMap`.
/// Each tile is shrunk by `inset` (the 1-pt gutter the map draws), so the 2-pt strip between neighbours resolves to
/// nil; rects are half-open (`minX ≤ x < maxX`) so a shared edge belongs to exactly one tile.
struct SpaceMapHitTest {
    let tiles: [(id: Int32, rect: CGRect)]
    let inset: CGFloat

    init(_ tiles: [(id: Int32, rect: CGRect)], inset: CGFloat = 1) {
        self.tiles = tiles
        self.inset = inset
    }

    /// Linear scan: the map never holds more than 200 tiles, so this is cheaper than maintaining an index.
    func tile(at p: CGPoint) -> Int32? {
        for t in tiles {
            let r = t.rect.insetBy(dx: inset, dy: inset)
            guard r.width > 0, r.height > 0 else { continue }
            if p.x >= r.minX, p.x < r.maxX, p.y >= r.minY, p.y < r.maxY { return t.id }
        }
        return nil
    }
}
