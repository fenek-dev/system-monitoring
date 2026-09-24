import CoreGraphics
import Foundation
import MonitorModel
import Testing
@testable import MonitorUIKit

@Suite struct TreemapLayoutTests {
    let rect = CGRect(x: 0, y: 0, width: 760, height: 190)

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func area(_ r: CGRect) -> Double { Double(r.width * r.height) }

    func checkInvariants(_ values: [Double], other: Int?, in rect: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        let rects = TreemapLayout.squarify(values, otherIndex: other, in: rect)
        #expect(rects.count == values.count, sourceLocation: sourceLocation)
        let total = values.filter { $0 > 0 && $0.isFinite }.reduce(0, +)
        guard total > 0 else {
            #expect(rects.allSatisfy { $0 == .zero }, sourceLocation: sourceLocation)
            return
        }
        let rectArea = area(rect)
        var sum = 0.0
        for (v, r) in zip(values, rects) {
            if !(v > 0 && v.isFinite) {
                #expect(r == .zero, "zero value → .zero", sourceLocation: sourceLocation)
                continue
            }
            // Areas ∝ values (±0.5 % of the item's expected area, or a tiny absolute slack).
            let expected = rectArea * v / total
            #expect(abs(area(r) - expected) <= max(expected * 0.005, 1e-6), "area \(area(r)) vs \(expected)",
                    sourceLocation: sourceLocation)
            // Inside the container.
            #expect(r.minX >= rect.minX - 1e-6 && r.minY >= rect.minY - 1e-6 && r.maxX <= rect.maxX + 1e-6
                        && r.maxY <= rect.maxY + 1e-6, "\(r) outside", sourceLocation: sourceLocation)
            sum += area(r)
        }
        // Union == rect (non-overlapping pieces whose areas add up to the container).
        #expect(abs(sum - rectArea) < rectArea * 1e-9 + 1e-6, sourceLocation: sourceLocation)
        let live = rects.filter { $0 != .zero }
        for i in live.indices {
            for j in live.indices where j > i {
                let inter = live[i].intersection(live[j])
                #expect(inter.isNull || area(inter) < 1e-6, "overlap \(live[i]) \(live[j])", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func invariantsOnDesignSample() {
        // History "App share" sample: Xcode 812 %, Final Cut 96, Safari 19, WindowServer 14, docker 11, Other 30.
        checkInvariants([812, 96, 19, 14, 11, 30], other: 5, in: rect)
        checkInvariants([812, 96, 19, 14, 11], other: nil, in: rect)
    }

    @Test func resultsAreInInputOrderAndLargestIsTopLeft() {
        let values: [Double] = [3, 10, 1, 6]
        let rects = TreemapLayout.squarify(values, otherIndex: nil, in: rect)
        let order = rects.indices.sorted { area(rects[$0]) > area(rects[$1]) }
        #expect(order == [1, 3, 0, 2])
        #expect(rects[1].origin == rect.origin)
    }

    @Test func otherIsLaidOutLastInTheBottomRightCorner() {
        for (w, h) in [(760.0, 190.0), (200.0, 500.0), (300.0, 300.0)] {
            let r = CGRect(x: 10, y: 20, width: w, height: h)
            let rects = TreemapLayout.squarify([50, 5, 30, 20, 10], otherIndex: 1, in: r)
            #expect(abs(rects[1].maxX - r.maxX) < 1e-6 && abs(rects[1].maxY - r.maxY) < 1e-6, "\(rects[1]) in \(r)")
            // Other is not the largest yet still placed last (not in the top-left).
            #expect(rects[1].origin != r.origin)
        }
    }

    @Test func zerosAndDegenerateInput() {
        #expect(TreemapLayout.squarify([], otherIndex: nil, in: rect) == [])
        #expect(TreemapLayout.squarify([0, 0], otherIndex: nil, in: rect) == [.zero, .zero])
        #expect(TreemapLayout.squarify([1, 2], otherIndex: nil, in: .zero) == [.zero, .zero])
        let r = TreemapLayout.squarify([0, 5, .nan, -1, 5], otherIndex: 0, in: rect)
        #expect(r[0] == .zero && r[2] == .zero && r[3] == .zero)
        checkInvariants([0, 5, .nan, -1, 5], other: 0, in: rect)
        let single = TreemapLayout.squarify([7], otherIndex: nil, in: rect)
        #expect(single == [rect])
        let onlyOther = TreemapLayout.squarify([7], otherIndex: 0, in: rect)
        #expect(onlyOther == [rect])
    }

    @Test(.enUS) func tileLabelsAndValues() {
        #expect(TTTreemap.showsName(CGSize(width: 60, height: 28)))
        #expect(!TTTreemap.showsName(CGSize(width: 59, height: 100)))
        #expect(!TTTreemap.showsName(CGSize(width: 200, height: 27)))
        #expect(TTTreemap.showsValue(CGSize(width: 60, height: 40)))
        #expect(!TTTreemap.showsValue(CGSize(width: 60, height: 39)))
        #expect(!TTTreemap.showsValue(CGSize(width: 38, height: 64)))
        let u = UnitPreferences()
        #expect(TTTreemap.valueText(812, metric: .cpu, units: u) == "812% CPU")
        #expect(TTTreemap.valueText(41, metric: .gpu, units: u) == "41% GPU")
        #expect(TTTreemap.valueText(4_101_693_768, metric: .memory, units: u) == "3.82 GB")
        #expect(TTTreemap.valueText(12_400_000, metric: .netRx, units: u) == "12.4 MB/s")
        #expect(TTTreemap.valueText(7.15, metric: .energy, units: u) == "7.15 W")
    }

    @Test func worstAspectRatio() {
        #expect(TreemapLayout.worstAspectRatio([CGRect(x: 0, y: 0, width: 10, height: 10)]) == 1)
        #expect(TreemapLayout.worstAspectRatio([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 2, height: 8),
                                                .zero]) == 4)
        #expect(TreemapLayout.worstAspectRatio([]) == 1)
    }

    /// Reference: slice-and-dice (all slices along the longer side, same sorted order).
    func sliceAndDice(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        var x = rect.minX, y = rect.minY
        let horizontal = rect.width >= rect.height
        return values.sorted(by: >).map { v in
            let f = v / total
            if horizontal {
                defer { x += rect.width * f }
                return CGRect(x: x, y: rect.minY, width: rect.width * f, height: rect.height)
            } else {
                defer { y += rect.height * f }
                return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height * f)
            }
        }
    }

    @Test func squarifiedBeatsSliceAndDiceOn200Seeds() {
        for seed in 0..<200 {
            var rng = SplitMix(state: UInt64(seed))
            let n = Int.random(in: 2...24, using: &rng)
            let values = (0..<n).map { _ in pow(Double.random(in: 0.01...1, using: &rng), 2) * 100 }
            let w = Double.random(in: 120...900, using: &rng), h = Double.random(in: 80...400, using: &rng)
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            let other: Int? = seed % 3 == 0 ? n - 1 : nil
            checkInvariants(values, other: other, in: r)
            let named = other.map { o in values.enumerated().filter { $0.offset != o }.map(\.element) } ?? values
            let s = TreemapLayout.worstAspectRatio(TreemapLayout.squarify(named, otherIndex: nil, in: r))
            let d = TreemapLayout.worstAspectRatio(sliceAndDice(named, in: r))
            #expect(s <= d + 1e-9, "seed \(seed): squarified \(s) > slice-and-dice \(d)")
        }
    }
}
