import Foundation
import Testing
import MonitorModel
@testable import MonitorMocks

@Suite struct MockHistoryProviderTests {
    static let end = MockDataProvider.referenceDate

    // MARK: - Determinism

    @Test func sameSeedSameSeries() async throws {
        let a = MockHistoryProvider(scenario: .calm, seed: 7, end: Self.end)
        let b = MockHistoryProvider(scenario: .calm, seed: 7, end: Self.end)
        let sa = try await a.series([.cpuUsage, .socTemp], range: .day, end: Self.end)
        let sb = try await b.series([.cpuUsage, .socTemp], range: .day, end: Self.end)
        #expect(sa == sb)
    }

    // MARK: - Bucket honored

    @Test func honorsExplicitBucket() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let points = try await p.series([.cpuUsage], range: .hour, end: Self.end, bucket: .seconds(600))
        // 1 h / 10 min = 6 buckets.
        #expect(points[.cpuUsage]?.count == 6)
    }

    @Test func defaultBucketMatchesDisplayBucket() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let points = try await p.series([.cpuUsage], range: .day, end: Self.end, bucket: nil)
        #expect(points[.cpuUsage]?.count == 288)   // 24 h / 5 min (DESIGN §5.10)
    }

    // MARK: - Gaps

    @Test func pausedHourIsAGap() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let calendar = Calendar.current
        let gapDay = calendar.date(byAdding: .day, value: -HistorySignal.pausedGapDaysAgo, to: calendar.startOfDay(for: Self.end))!
        let gapHourStart = calendar.date(bySettingHour: HistorySignal.pausedGapHour, minute: 5, second: 0, of: gapDay)!
        let outsideGap = calendar.date(bySettingHour: HistorySignal.pausedGapHour + 3, minute: 0, second: 0, of: gapDay)!
        #expect(try await p.total(.cpuUsage, in: DateInterval(start: outsideGap, duration: 60)) != nil)  // sanity: elsewhere works
        _ = gapHourStart
        let points = try await p.series([.cpuUsage], range: .day,
                                         end: calendar.date(byAdding: .day, value: 1, to: gapDay)!, bucket: .seconds(300))
        let gapBucketIndex = HistorySignal.pausedGapHour * 12   // 12 five-minute buckets/hour
        #expect(points[.cpuUsage]?[gapBucketIndex].value == nil)
    }

    // MARK: - Coverage

    @Test func calmCoverageIsThirtyDays() async throws {
        let p = MockHistoryProvider(scenario: .calm, end: Self.end)
        let cov = try await p.coverage()
        #expect(cov?.end == Self.end)
        #expect(abs((cov?.duration ?? 0) - 30 * 86_400) < 1)
    }

    @Test func collectingCoverageIsShort() async throws {
        let p = MockHistoryProvider(scenario: .collecting, end: Self.end)
        let cov = try await p.coverage()
        #expect((cov?.duration ?? 9_999) < 3_600)
    }

    // MARK: - Events (the artboard's storyline)

    @Test func eventsIncludeTheArtboardStoryline() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let today = Calendar.current.startOfDay(for: Self.end)
        let events = try await p.events(in: DateInterval(start: today, end: Self.end))
        #expect(events.contains { $0.label == "Xcode build" })
        #expect(events.contains { $0.label == "Final Cut Pro export" })
    }

    // MARK: - Per-app queries

    @Test func appSeriesForKnownAppIsNonEmptyAndBounded() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let xcode = AppKey(kind: .app, id: "com.apple.dt.Xcode")
        let series = try await p.appSeries(xcode, [.cpu], range: .hour, end: Self.end)
        let values = series[.cpu]?.compactMap(\.value) ?? []
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0 >= 0 })
    }

    @Test func appSharesSumToOne() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let shares = try await p.appShares(at: Self.end, metric: .cpu, range: .live, limit: 20)
        #expect(!shares.isEmpty)
        #expect(abs(shares.map(\.fraction).reduce(0, +) - 1) < 0.001)
    }

    @Test func topAppsSortedByAverageDescending() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let interval = DateInterval(start: Self.end.addingTimeInterval(-3_600), end: Self.end)
        let top = try await p.topApps(.cpu, in: interval, limit: 5)
        let averages = top.map(\.average)
        #expect(averages == averages.sorted(by: >))
        #expect(top.first?.identity.displayName == "Xcode")
    }

    // MARK: - Export

    @Test func exportCSVWritesRowsWithTheSpecifiedColumns() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mock-history-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = try await p.exportCSV(range: .hour, end: Self.end, to: url)
        #expect(summary.rows > 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("timestamp_iso8601,cpu_pct,gpu_pct,mem_pressure_pct,net_down_Bps,net_up_Bps,soc_temp_c,package_w"))
    }

    // MARK: - Performance (advisory: report the number; ARCHITECTURE Wm brief targets <20 ms/query)

    @Test func thirtyDayQueryIsFast() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let metrics: [HistoryMetric] = [.cpuUsage, .gpuUsage, .memUsed, .netRx, .netTx, .socTemp, .packageWatts]
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await p.series(metrics, range: .month, end: Self.end)
        }
        #expect(elapsed < .milliseconds(100))
    }
}
