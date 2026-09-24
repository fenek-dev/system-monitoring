import Foundation
import MonitorModel
import Testing
@testable import MonitorUIKit

@Suite struct ChartMathTests {
    let london = TimeZone(identifier: "Europe/London")!
    let enUS = Locale(identifier: "en_US")
    // Thursday 24 September 2026, 14:35 London.
    let end = Date(timeIntervalSince1970: 1_790_257_000)

    @Test func axisLabelSets() {
        #expect(TTTimeAxis.labels(range: .live, end: end) == ["60 s ago", "45 s", "30 s", "15 s", "now"])
        #expect(TTTimeAxis.labels(range: .hour, end: end) == ["60 m ago", "45 m", "30 m", "15 m", "now"])
        #expect(TTTimeAxis.labels(range: .day, end: end) == ["24 h ago", "18 h", "12 h", "6 h", "now"])
        #expect(TTTimeAxis.labels(range: .day, end: end, style: .clock)
            == ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00", "24:00"])
        let week = TTTimeAxis.labels(range: .week, end: end, timeZone: london, locale: enUS)
        #expect(week.count == 7)
        #expect(week.last == "Thu")
        #expect(week.first == "Fri")
        let month = TTTimeAxis.labels(range: .month, end: end, timeZone: london, locale: enUS)
        #expect(month == ["25 Aug", "2 Sep", "9 Sep", "17 Sep", "24 Sep"])
    }

    @Test func stackedLayersAreCumulativeWithGaps() {
        func p(_ v: [Double?]) -> [SeriesPoint] {
            v.enumerated().map { SeriesPoint(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element) }
        }
        let layers = TTStackedArea.cumulative([p([1, 2, 3]), p([10, nil, 30]), p([100, 200, 300])])
        #expect(layers.map { $0.map(\.value) } == [[1, 2, 3], [11, nil, 33], [111, nil, 333]])
    }
}
