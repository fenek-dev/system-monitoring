import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// DESIGN §3.9 Thermals page goldens (`__Snapshots__/thermals-*.png`).
@MainActor
@Suite("ThermalsSnapshotTests", .enabled { await ScreenFixture.snapshotsAvailable })
struct ThermalsSnapshotTests {
    // restricted/collecting renders are identical to calm for this page (no process rows; firstTick covers
    // "Collecting…"), so they have no goldens of their own.
    @Test func calm() { assertScreen("thermals", scenario: .calm) }
    @Test func thermalCritical() { assertScreen("thermals", scenario: .thermalCritical) }
    @Test func sensorsUnavailable() { assertScreen("thermals", scenario: .sensorsUnavailable) }

    /// A raw sensor row clicked open: its 30-pt 1H strip ("Collecting…" until the page has recorded samples).
    @Test func rawStripOpen() {
        let key = ThermalGroupCopy.rawKey(RawTemperature(name: "PMU die", group: .cpuPerformance, source: .hid))
        assertSnapshot(ThermalsPage(showRawSensors: true, openStrips: [key]).screenEnvironment(.calm, page: .thermals),
                       size: ScreenSize.pageContent, named: "thermals-rawstrip-calm")
    }

    /// First tick: one sample → chart "Collecting…", values already shown.
    @Test func firstTick() {
        assertSnapshot(ThermalsPage().telltaleEnvironment(ScreenFixture.context(.collecting, page: .thermals, ticks: 0)),
                       size: ScreenSize.pageContent, named: "thermals-firsttick-collecting")
    }

    /// "Show raw sensors" expanded: groups with their raw HID/SMC children at indent 20.
    @Test func rawSensorsExpanded() {
        assertSnapshot(ThermalsPage(showRawSensors: true).screenEnvironment(.calm, page: .thermals),
                       size: ScreenSize.pageContent, named: "thermals-raw-calm")
    }
}

@MainActor
@Suite("ThermalsPageLogicTests")
struct ThermalsPageLogicTests {
    private func thermals() -> ThermalSnapshot {
        ThermalSnapshot(
            pressure: .nominal, socAverage: 61,
            groups: [
                TemperatureGroupSnapshot(group: .ssd, average: 41, maximum: 41, sensorCount: 1),
                TemperatureGroupSnapshot(group: .cpuPerformance, average: 66, maximum: 74, sensorCount: 8),
                TemperatureGroupSnapshot(group: .soc, average: 61, maximum: 63, sensorCount: 12),
            ],
            sensors: [
                RawTemperature(name: "PMU die", celsius: 70, group: .cpuPerformance, source: .hid),
                RawTemperature(name: "PMU die 2", celsius: 72, group: .cpuPerformance, source: .hid),
                RawTemperature(name: "Mystery", celsius: 30, group: .airflow, source: .smc),
            ])
    }

    @Test func groupsInDesignOrderWithDetails() {
        let lines = SensorsCardLines.lines(thermals(), showRaw: false)
        #expect(lines.map(\.name) == ["CPU performance cores", "SoC package", "SSD"])
        #expect(lines.map(\.detail) == ["avg of 8", "PMU die", "NAND"])
        #expect(lines.map(\.parity) == [0, 1, 0])
        #expect(lines.allSatisfy { $0.depth == 0 && $0.detailHelp == nil })
    }

    /// Ruling: the E-core group is flagged approximate (detail + tooltip).
    @Test func eCoreGroupIsApproximate() {
        var t = thermals()
        t.groups.append(TemperatureGroupSnapshot(group: .cpuEfficiency, average: 54, maximum: 57, sensorCount: 4))
        let line = SensorsCardLines.lines(t, showRaw: false).first { $0.name == "CPU efficiency cores" }
        #expect(line?.detail == "avg of 4 · approximate")
        #expect(line?.detailHelp == ThermalGroupCopy.eCoreApproximate)
    }

    /// Clicking toggles a raw row's strip; group rows ignore clicks.
    @Test func rawStripToggle() {
        let lines = SensorsCardLines.lines(thermals(), showRaw: true)
        let raw = lines[1], group = lines[0]
        var open = SensorsCardLines.toggled([], raw)
        #expect(open == [raw.id])
        #expect(SensorsCardLines.toggled(open, group) == open)
        open = SensorsCardLines.toggled(open, raw)
        #expect(open.isEmpty)
    }

    @Test func approximateMappingCaption() {
        var t = thermals()
        #expect(SensorsCardLines.caption(t) == "3 groups · 3 raw sensors")
        t.approximateMapping = true
        #expect(SensorsCardLines.caption(t) == "Approximate mapping · 3 groups · 3 raw sensors")
    }

    /// Non-live ranges read the store (bucketed); Live never queries it.
    @Test func nonLiveRangeReadsStore() async {
        let history = MockHistoryProvider(scenario: .calm)
        let end = MockDataProvider.referenceDate
        let hour = await SystemRangeSeries.load([.cpuPTemp, .gpuTemp], range: .hour, end: end, history: history)
        #expect(ChartSegments.sampleCount(hour[.cpuPTemp] ?? []) >= 2)
        #expect(await SystemRangeSeries.load([.cpuPTemp], range: .live, end: end, history: history).isEmpty)
        #expect(SystemRangeSeries.Key(range: .hour, end: end) == SystemRangeSeries.Key(range: .hour, end: end + 5))
        #expect(SystemRangeSeries.Key(range: .live, end: end) == SystemRangeSeries.Key(range: .live, end: end + 60))
    }

    @Test func fittedRowLimit() {
        // header 26 + 4 top padding, then whole 32-pt rows only.
        #expect(SystemFittedRows<EmptyView>.limit(height: 30 + 32 * 6 + 31, rowHeight: 32, headerHeight: 26) == 6)
        #expect(SystemFittedRows<EmptyView>.limit(height: 10, rowHeight: 32, headerHeight: 26) == 0)
        #expect(SystemPageSort.descending([1.0, nil, 3.0, 3.0], by: { $0 }).map { $0 } == [3.0, 3.0, 1.0, nil])
    }

    @Test func rawModeNestsSensorsHottestFirstAndCollectsOrphans() {
        let lines = SensorsCardLines.lines(thermals(), showRaw: true)
        #expect(lines.map(\.name) == ["CPU performance cores", "PMU die 2", "PMU die", "SoC package", "SSD",
                                      "Other", "Mystery"])
        #expect(lines.map(\.depth) == [0, 1, 1, 0, 0, 0, 1])
        // Children share their parent's zebra parity.
        #expect(lines.map(\.parity) == [0, 0, 0, 1, 0, 1, 1])
        #expect(lines[1].detail == "HID" && lines[6].detail == "SMC")
    }

    @Test func fanLabels() {
        let one = FansCardLabels.labeled([FanSnapshot(id: 0, name: "F0")])
        let two = FansCardLabels.labeled([FanSnapshot(id: 0), FanSnapshot(id: 1)])
        let three = FansCardLabels.labeled([FanSnapshot(id: 0), FanSnapshot(id: 1), FanSnapshot(id: 2)])
        #expect(one.map(\.name) == ["Fan"])
        #expect(two.map(\.name) == ["Left fan", "Right fan"])
        #expect(three.map(\.name) == ["Fan 1", "Fan 2", "Fan 3"])
    }

    @Test func sensorBarScale() {
        #expect(ThermalSensorBar.fraction(20) == 0)
        #expect(ThermalSensorBar.fraction(105) == 1)
        #expect(ThermalSensorBar.fraction(10) == 0)
        #expect(ThermalSensorBar.fraction(62.5) == 0.5)
        #expect(ThermalSensorBar.fraction(nil) == nil)
    }

    @Test func peakTrackerBucketsAndWindow() {
        let tracker = ThermalPeakTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.record("k", 50, at: t0)
        tracker.record("k", 55, at: t0.addingTimeInterval(1))       // same 15-s bucket → max
        tracker.record("k", 52, at: t0.addingTimeInterval(20))
        #expect(tracker.peak("k") == 55)
        let pts = tracker.points("k", end: t0.addingTimeInterval(20))
        #expect(pts.count == 240)
        #expect(pts.compactMap(\.value) == [55, 52])
        // An hour later the old buckets fall out of the window (running peak recomputed).
        tracker.record("k", 40, at: t0.addingTimeInterval(3_700))
        #expect(tracker.peak("k") == 40)
        tracker.prune(keeping: [])
        #expect(tracker.peak("k") == nil)
        // Seeding from a series (the live ring when the page opens).
        tracker.seed("s", [SeriesPoint(time: t0, value: 61), SeriesPoint(time: t0 + 1, value: nil),
                           SeriesPoint(time: t0 + 30, value: 64)])
        #expect(tracker.peak("s") == 64)
        #expect(!tracker.isEmpty)
    }

    @Test func pressureCopy() {
        #expect(ThermalPressure.allCases.map(ThermalLevelCopy.statSub) ==
            ["no throttling", "mild fan boost", "clock limiting likely", "heavy throttling"])
        #expect(ThermalPressure.allCases.map(ThermalLevelCopy.scaleDetail) ==
            ["Full performance", "Mild fan boost", "Clock limiting likely", "Heavy throttling"])
    }
}
