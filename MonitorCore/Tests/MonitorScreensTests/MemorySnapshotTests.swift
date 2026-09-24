import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Memory snapshots")
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

    /// The span i → i+1 takes sample i's level: each run ends on the next run's first sample; a trailing single
    /// sample draws nothing.
    @Test func pressureRunsSwitchAtTheFirstNewLevelSample() {
        let runs = MemoryPressureChart.runs([.normal, .normal, .warning, .warning, .normal])
        #expect(runs == [.init(level: .normal, range: 0...2), .init(level: .warning, range: 2...4)])
        #expect(MemoryPressureChart.runs([.normal, .critical]) == [.init(level: .normal, range: 0...1)])
        #expect(MemoryPressureChart.runs([.warning]).isEmpty)
    }

    /// ICR-12: bucket averages map > 2.5 → critical, > 1.0 → warning, else normal; gaps and pre-ICR rows → normal.
    @Test func pressureLevelsFromStoredMetric() {
        #expect(MemoryPressureCard.level(1.0) == .normal)
        #expect(MemoryPressureCard.level(1.4) == .warning)
        #expect(MemoryPressureCard.level(2.6) == .critical)
        let t = Date(timeIntervalSince1970: 0)
        let raw = [1.0, 2.0, nil, 4.0].enumerated().map { SeriesPoint(time: t.addingTimeInterval(Double($0.offset)), value: $0.element) }
        #expect(MemoryPressureCard.levels(raw, count: 5) == [.normal, .warning, .normal, .critical, .normal])
        let warning = ScreenFixture.live(.memoryWarning)
        let series = warning.series(.memPressureLevel)
        #expect(warning.memory.pressureLevel == .warning)
        #expect(MemoryPressureCard.levels(series, count: series.count).last == .warning)   // live ring, latest sample
    }

    /// Ruling: the consumers table has no Compressed/Private/Ports columns; groups sort by memory, nil last.
    @Test func consumersSortedByMemory() {
        let rows = MemoryConsumersCard.rows(ScreenFixture.live(.restricted))
        #expect(!rows.isEmpty)
        #expect(zip(rows, rows.dropFirst()).allSatisfy { a, b in
            guard let bm = b.memory else { return true }
            return (a.memory ?? 0) >= bm && a.memory != nil
        })
    }

    /// A6: groups whose members we cannot read show the §3.12 root-memory wording.
    @Test func memoryReasonForHiddenMembers() throws {
        var app = try #require(ScreenFixture.live(.calm).apps.first)
        app.memory = nil
        app.hiddenProcessCount = 2
        #expect(MemoryConsumersCard.memoryReason(app, health: [:]) == "Requires root · updated when Processes is open")
        app.memory = 1_000
        #expect(MemoryConsumersCard.memoryReason(app, health: [:]) == nil)
    }

    /// A7: the level word's color follows the level (Normal tertiary, Warning amber, Critical red).
    @Test func pressureWordTint() {
        let items = MemoryStatStrip.items(ScreenFixture.live(.memoryWarning))
        #expect(items[1].detail == "Warning")
        #expect(items[1].detailTint == TTColor.statusElevated)
        #expect(MemoryStatStrip.items(ScreenFixture.live(.calm))[1].detailTint == TTColor.textTertiary)
    }
}
