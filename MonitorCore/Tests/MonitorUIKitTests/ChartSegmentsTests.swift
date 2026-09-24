import Foundation
import MonitorModel
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
