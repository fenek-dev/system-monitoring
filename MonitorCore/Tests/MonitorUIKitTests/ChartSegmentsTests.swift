import Foundation
import MonitorModel
import SwiftUI
import Testing
@testable import MonitorUIKit

@Suite struct ChartSegmentsTests {
    func pts(_ values: [Double?]) -> [SeriesPoint] {
        values.enumerated().map { SeriesPoint(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element) }
    }

    @Test func runsSplitAtGaps() {
        #expect(ChartSegments.runs(pts([1, 2, nil, 3, 4, 5, nil, nil, 6])) == [0..<2, 3..<6, 8..<9])
        #expect(ChartSegments.runs(pts([nil, nil])) == [])
        #expect(ChartSegments.runs(pts([])) == [])
        #expect(ChartSegments.runs(pts([1, 2, 3])) == [0..<3])
    }

    @Test func nanIsAGap() {
        #expect(ChartSegments.runs(pts([1, .nan, 2])) == [0..<1, 2..<3])
        #expect(ChartSegments.sampleCount(pts([1, .nan, nil, 2])) == 2)
    }

    @Test func xSpansTheWidthEvenly() {
        #expect(ChartSegments.x(index: 0, count: 60, width: 118) == 0)
        #expect(ChartSegments.x(index: 59, count: 60, width: 118) == 118)
        #expect(ChartSegments.x(index: 1, count: 3, width: 100) == 50)
        #expect(ChartSegments.x(index: 0, count: 1, width: 100) == 0)
    }

    @Test func yIsClampedToTheDomain() {
        #expect(ChartSegments.y(value: 0, domain: 0...100, height: 40) == 40)
        #expect(ChartSegments.y(value: 100, domain: 0...100, height: 40) == 0)
        #expect(ChartSegments.y(value: 50, domain: 0...100, height: 40) == 20)
        #expect(ChartSegments.y(value: 250, domain: 0...100, height: 40) == 0)
        #expect(ChartSegments.y(value: -5, domain: 0...100, height: 40) == 40)
        #expect(ChartSegments.y(value: 72, domain: 40...105, height: 65) == 33)
        #expect(ChartSegments.y(value: 3, domain: 3...3, height: 10) == 10) // degenerate domain → baseline
    }

    struct PathStats: Equatable {
        var moves = 0, lines = 0, closes = 0
        var maxYAtBaseline = 0 // points on the baseline
    }

    func stats(_ path: Path, baseline: CGFloat) -> PathStats {
        var s = PathStats()
        path.forEach { el in
            switch el {
            case .move(let p):
                s.moves += 1
                if p.y == baseline { s.maxYAtBaseline += 1 }
            case .line(let p):
                s.lines += 1
                if p.y == baseline { s.maxYAtBaseline += 1 }
            case .closeSubpath: s.closes += 1
            default: break
            }
        }
        return s
    }

    /// Canvas gap rule: each run is its own line subpath and its own closed area; gaps are never bridged.
    @Test func gapsBreakLineAndCloseAreaPerRun() {
        let p = pts([10, 20, 30, nil, nil, 40, 50, nil, 60, 70, 80])
        var line = Path()
        var area: Path? = Path()
        ChartSegments.addSeries(p, domain: 0...100, in: CGSize(width: 100, height: 50), line: &line, area: &area)
        let l = stats(line, baseline: 50)
        #expect(l.moves == 3)          // three runs
        #expect(l.lines == 2 + 1 + 2)  // n−1 segments per run
        #expect(l.closes == 0)
        let a = stats(area!, baseline: 50)
        #expect(a.moves == 3)
        #expect(a.closes == 3)
        // Each run: move to baseline, up, along, down to baseline, back along baseline → 3 baseline points per run.
        #expect(a.maxYAtBaseline == 9)
        // No segment of the line spans the gap between x(2)=20 and x(5)=50.
        var prev: CGPoint?
        var bridged = false
        line.forEach { el in
            switch el {
            case .move(let q): prev = q
            case .line(let q):
                if let a = prev, a.x <= 20, q.x >= 50 { bridged = true }
                prev = q
            default: break
            }
        }
        #expect(!bridged)
    }

    /// Ruling N2 (Live 1-s grid): gaps of up to 6 slots between samples are bridged (5-s background cadence = 4 empty
    /// slots); a longer gap (a real pause) still breaks the line; bridging is off by default (stored ranges).
    @Test func liveGridBridgesShortGapsOnly() {
        let b = ChartSegments.liveBridgeSlots
        #expect(b == 6)
        // 5-s cadence then 1-s points: one run.
        let cadence: [Double?] = [1, nil, nil, nil, nil, 2, nil, nil, nil, nil, 3, 4, 5]
        #expect(ChartSegments.runs(pts(cadence), bridge: b) == [0..<13])
        #expect(ChartSegments.runs(pts(cadence)) == [0..<1, 5..<6, 10..<13])   // strict rule: two lone points
        // 6 empty slots bridge, 7 break.
        #expect(ChartSegments.runs(pts([1] + Array(repeating: nil, count: 6) + [2]), bridge: b) == [0..<8])
        #expect(ChartSegments.runs(pts([1] + Array(repeating: nil, count: 7) + [2]), bridge: b) == [0..<1, 8..<9])
        // Leading/trailing nils are not part of a run.
        #expect(ChartSegments.runs(pts([nil, 1, nil, 2, nil]), bridge: b) == [1..<4])

        var line = Path()
        var area: Path? = Path()
        ChartSegments.addSeries(pts(cadence), domain: 0...10, in: CGSize(width: 120, height: 50), line: &line,
                                area: &area, bridge: b)
        let l = stats(line, baseline: 50)
        #expect(l.moves == 1 && l.lines == 4)        // 5 samples, one subpath
        #expect(stats(area!, baseline: 50).closes == 1)

        var paused = Path()
        var none: Path?
        let pause: [Double?] = [1, 2] + Array(repeating: nil, count: 20) + [3, 4]
        ChartSegments.addSeries(pts(pause), domain: 0...10, in: CGSize(width: 120, height: 50), line: &paused,
                                area: &none, bridge: b)
        #expect(stats(paused, baseline: 50).moves == 2)
    }

    /// Ruling N2: a sample that is a run of its own draws as a dot (it has no segment).
    @Test func loneSamplesDrawAsDots() {
        let p = pts([nil, 5, nil, nil, nil, nil, nil, nil, nil, 6, 7, nil])
        #expect(ChartSegments.loneSamples(p) == [1])
        #expect(ChartSegments.loneSamples(p, bridge: 6) == [1])            // 7 empty slots: still alone
        #expect(ChartSegments.loneSamples(pts([nil, 5, nil, nil, 6]), bridge: 6) == [])
        let dots = ChartSegments.loneDots(p, domain: 0...10, in: CGSize(width: 110, height: 50), radius: 2)
        #expect(dots.boundingRect == CGRect(x: 10 - 2, y: 25 - 2, width: 4, height: 4))
        // "Collecting…" stays until the window holds 2 samples.
        #expect(ChartSegments.sampleCount(pts([nil, 5, nil])) < 2)
    }

    @Test func flippedAreaHangsFromTheTop() {
        var line = Path()
        var area: Path? = Path()
        ChartSegments.addSeries(pts([50, 100]), domain: 0...100, in: CGSize(width: 10, height: 40), line: &line, area: &area,
                                flipped: true)
        // Value 0 would sit on the top edge; 50 hangs to the middle, 100 reaches the bottom.
        #expect(line.boundingRect == CGRect(x: 0, y: 20, width: 10, height: 20))
        #expect(stats(area!, baseline: 0).maxYAtBaseline == 3)
    }

    @Test func decimateKeepsShortSeries() {
        let p = pts([1, 2, 3])
        #expect(ChartSegments.decimate(p, maxPoints: 10) == p)
    }

    @Test func decimateBoundsCountAndKeepsExtremes() {
        var values: [Double?] = (0..<1000).map { Double($0 % 10) }
        values[500] = 99
        values[700] = -7
        let d = ChartSegments.decimate(pts(values), maxPoints: 100)
        #expect(d.count <= 100)
        #expect(d.compactMap(\.value).max() == 99)
        #expect(d.compactMap(\.value).min() == -7)
        // Time order preserved.
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    @Test func decimatePreservesGaps() {
        var values: [Double?] = Array(repeating: 1, count: 600)
        for i in 300..<310 { values[i] = nil }
        let d = ChartSegments.decimate(pts(values), maxPoints: 60)
        #expect(d.contains { $0.value == nil })
        #expect(ChartSegments.runs(d).count == 2)
    }
}
