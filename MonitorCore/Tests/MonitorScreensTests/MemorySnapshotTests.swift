import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Memory snapshots", .serialized)
@MainActor
struct MemorySnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted, .memoryWarning])
    func memory(_ scenario: MockScenario) {
        assertScreen("memory", scenario: scenario)
    }

    @Test func statStripBindings() {
        let items = MemoryStatStrip.items(ScreenFixture.live(.calm))
        #expect(items.map(\.label) == ["Used", "Memory pressure", "Swap used", "Compressed", "Page-ins · outs"])
        #expect(items[0].detail == "of 24 GB")
        #expect(items[1].detail == "Normal")
        #expect(items[2].detail == "of 2.00 GB allocated")
        #expect(items[3].detail == "ratio 2.8 : 1")
        #expect(items[4].value == "412 · 0")
    }

    @Test func compositionOrder() {
        let parts = MemoryCompositionCard.parts(ScreenFixture.live(.calm).memory)
        #expect(parts.map(\.label) == ["App memory", "Wired", "Compressed", "Cached files", "Free"])
    }

    /// The span i → i+1 takes sample i's level; runs overlap by exactly the boundary sample.
    @Test func pressureRunsSwitchAtTheFirstNewLevelSample() {
        let t = Date(timeIntervalSince1970: 0)
        let pts = (0..<5).map { SeriesPoint(time: t.addingTimeInterval(Double($0)), value: 0.5) }
        let runs = MemoryPressureChart.runs(pts, [.normal, .normal, .warning, .warning, .normal])
        #expect(runs.map(\.0) == [.normal, .warning, .normal])
        #expect(runs[0].1.map { $0.value != nil } == [true, true, true, false, false])
        #expect(runs[1].1.map { $0.value != nil } == [false, false, true, true, true])
        #expect(runs[2].1.map { $0.value != nil } == [false, false, false, false, true])
    }

    /// ICR-12: bucket averages map > 2.5 → critical, > 1.0 → warning, else normal; gaps keep the previous level.
    @Test func pressureLevelsFromStoredMetric() {
        #expect(MemoryPressureCard.level(1.0) == .normal)
        #expect(MemoryPressureCard.level(1.4) == .warning)
        #expect(MemoryPressureCard.level(2.6) == .critical)
        let live = ScreenFixture.live(.calm)
        let t = Date(timeIntervalSince1970: 0)
        let raw = [1.0, 2.0, nil, 4.0].enumerated().map { SeriesPoint(time: t.addingTimeInterval(Double($0.offset)), value: $0.element) }
        #expect(MemoryPressureCard.levels(raw, count: 4, live: live) == [.normal, .warning, .warning, .critical])
        #expect(MemoryPressureCard.levels(ScreenFixture.live(.memoryWarning).series(.memPressureLevel), count: 1,
                                          live: live).first != nil)
    }

    /// Ruling: the consumers table has no Compressed/Private/Ports columns; restricted groups sort last ("—").
    @Test func consumersSortedByMemory() {
        let rows = MemoryConsumersCard.rows(ScreenFixture.live(.restricted))
        #expect(zip(rows, rows.dropFirst()).allSatisfy { ($0.memory ?? 0) >= ($1.memory ?? 0) })
    }
}
