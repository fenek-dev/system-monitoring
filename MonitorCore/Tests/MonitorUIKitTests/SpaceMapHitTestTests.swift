import CoreGraphics
import Testing
@testable import MonitorUIKit

@Suite struct SpaceMapHitTestTests {
    // Two tiles sharing the edge x = 100, one stacked below the left tile (shared edge y = 50).
    let tiles: [(id: Int32, rect: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 100, height: 50)),
        (2, CGRect(x: 100, y: 0, width: 100, height: 100)),
        (3, CGRect(x: 0, y: 50, width: 100, height: 50)),
        (TTSpaceMapLayout.smallerID, CGRect(x: 200, y: 0, width: 40, height: 100)),
    ]

    @Test func sharedEdgeBelongsToTileStartingThere() {
        let t = SpaceMapHitTest(tiles, inset: 0)
        #expect(t.tile(at: CGPoint(x: 100, y: 10)) == 2)
        #expect(t.tile(at: CGPoint(x: 99.999, y: 10)) == 1)
        #expect(t.tile(at: CGPoint(x: 10, y: 50)) == 3)
        #expect(t.tile(at: CGPoint(x: 10, y: 49.999)) == 1)
    }

    @Test func gutterAndOutsideResolveToNil() {
        let t = SpaceMapHitTest(tiles)
        #expect(t.tile(at: CGPoint(x: 100, y: 10)) == nil)
        #expect(t.tile(at: CGPoint(x: 99, y: 10)) == nil)
        #expect(t.tile(at: CGPoint(x: 101, y: 10)) == 2)
        #expect(t.tile(at: CGPoint(x: 98.999, y: 10)) == 1)
        #expect(t.tile(at: CGPoint(x: 0.5, y: 10)) == nil)
        #expect(t.tile(at: CGPoint(x: -5, y: 10)) == nil)
        #expect(t.tile(at: CGPoint(x: 300, y: 10)) == nil)
    }

    @Test func smallerTileReturnsItsOwnID() {
        #expect(SpaceMapHitTest(tiles).tile(at: CGPoint(x: 220, y: 50)) == TTSpaceMapLayout.smallerID)
    }

    @Test func zeroSizedRectsAreSkipped() {
        let t = SpaceMapHitTest([(9, .zero), (1, CGRect(x: 0, y: 0, width: 2, height: 2))])
        #expect(t.tile(at: .zero) == nil)
        #expect(SpaceMapHitTest([(9, .zero)], inset: 0).tile(at: .zero) == nil)
    }
}

@Suite struct TTSpaceMapLayoutTests {
    func tile(_ id: Int32, _ v: Double) -> TTSpaceMapTile {
        TTSpaceMapTile(id: id, value: v, label: "t\(id)", valueText: "\(v)")
    }

    @Test func tailUnderHalfPercentMergesIntoSmallerTile() {
        let layout = TTSpaceMapLayout.make([tile(1, 60), tile(2, 30), tile(3, 9.7), tile(4, 0.2), tile(5, 0.1)],
                                           in: CGSize(width: 600, height: 400))
        #expect(layout.shown.map(\.id) == [1, 2, 3])
        #expect(layout.smallerCount == 2)
        #expect(abs(layout.smallerValue - 0.3) < 1e-12)
        let last = layout.placed.last
        #expect(last?.tile.id == TTSpaceMapLayout.smallerID)
        #expect(last?.tile.label == "2 smaller items")
        // Other-style placement: the merged tile sits in the bottom-right corner.
        #expect(last.map { $0.rect.maxX == 600 && $0.rect.maxY == 400 } == true)
    }

    @Test func undersizedTilesMergeUntilEveryShownTileFits() {
        // 100 equal tiles in 300×100 pt: each wants 300 pt², far under 24×16 = 384 pt².
        let layout = TTSpaceMapLayout.make((1...100).map { tile(Int32($0), 1) }, in: CGSize(width: 300, height: 100))
        #expect(layout.shown.count < 100)
        #expect(layout.shown.count + layout.smallerCount == 100)
        for p in layout.placed where p.tile.kind == .normal {
            #expect(p.rect.width >= 24 && p.rect.height >= 16, "\(p.rect)")
        }
        #expect(layout.placed.last?.tile.kind == .smaller)
        #expect(abs(layout.placed.reduce(0) { $0 + $1.tile.value } - 100) < 1e-9)
    }

    @Test func singleTailItemIsSingular() {
        let layout = TTSpaceMapLayout.make([tile(1, 100), tile(2, 0.1)], in: CGSize(width: 600, height: 400))
        #expect(layout.placed.last?.tile.label == "1 smaller item")
    }

    @Test func noPositiveValuesYieldsNothingPlaced() {
        let layout = TTSpaceMapLayout.make([tile(1, 0), tile(2, .nan)], in: CGSize(width: 600, height: 400))
        #expect(layout.placed.isEmpty)
    }

    /// Advisory: 10k presorted children with cutoff + cap (target < 2 ms).
    @Test func tenThousandChildrenLayoutTime() {
        let tiles = (0..<10_000).map { tile(Int32($0), 1_000_000 / Double($0 + 1)) }
        let clock = ContinuousClock()
        var layout: TTSpaceMapLayout?
        let d = clock.measure { layout = TTSpaceMapLayout.make(tiles, in: CGSize(width: 760, height: 190)) }
        print("space-map 10k layout: \(d)")
        #expect((layout?.placed.count ?? 0) <= TTSpaceMapLayout.maxTiles + 1)
    }
}
