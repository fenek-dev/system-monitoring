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

    // Buckets are epoch-aligned (matching MonitorStore.Queries.Buckets), not anchored to `end`, so the
    // count is `windowSeconds / bucketSeconds` ± 1 depending on where `end` falls relative to a boundary
    // — never anchored precisely at the window edges. Exact alignment is covered by
    // `bucketTimestampsAreMultiplesOfTheBucketWidth`; these just check the count is in that ±1 range.

    @Test func honorsExplicitBucket() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let points = try await p.series([.cpuUsage], range: .hour, end: Self.end, bucket: .seconds(600))
        // 1 h / 10 min = 6 buckets, ±1 for epoch alignment.
        #expect((6...7).contains(points[.cpuUsage]?.count ?? -1))
    }

    @Test func defaultBucketMatchesDisplayBucket() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let points = try await p.series([.cpuUsage], range: .day, end: Self.end, bucket: nil)
        // 24 h / 5 min = 288 buckets (DESIGN §5.10), ±1 for epoch alignment.
        #expect((288...289).contains(points[.cpuUsage]?.count ?? -1))
    }

    /// The real store's `Buckets` are epoch-aligned, so every bucket's start must be an exact multiple
    /// of the bucket width in seconds since the Unix epoch — never anchored to `end`.
    @Test func bucketTimestampsAreMultiplesOfTheBucketWidth() async throws {
        let p = MockHistoryProvider(end: Self.end)
        let width: Double = 900   // 15 min
        let points = try await p.series([.cpuUsage], range: .day, end: Self.end, bucket: .seconds(Int64(width)))
        let times = points[.cpuUsage]?.map(\.time) ?? []
        #expect(!times.isEmpty)
        for t in times {
            let epoch = t.timeIntervalSince1970
            #expect(abs(epoch.truncatingRemainder(dividingBy: width)) < 0.001)
        }
        // Strictly increasing by exactly `width`, and every bucket starts at or before `end`.
        for (a, b) in zip(times, times.dropFirst()) { #expect(b.timeIntervalSince(a) == width) }
        #expect(times.last.map { $0 <= Self.end } ?? false)
    }

    // MARK: - Gaps

    @Test func pausedHourIsAGap() async throws {
        let p = MockHistoryProvider(end: Self.end)
        // `HistorySignal` computes day/hour against `ReferenceCalendar` (Europe/London, fixed), not the
        // host machine's `Calendar.current` — this test must agree, or it would only pass in that TZ.
        let calendar = ReferenceCalendar.calendar
        let gapDay = calendar.date(byAdding: .day, value: -HistorySignal.pausedGapDaysAgo, to: calendar.startOfDay(for: Self.end))!
        let outsideGap = calendar.date(bySettingHour: HistorySignal.pausedGapHour + 3, minute: 0, second: 0, of: gapDay)!
        #expect(try await p.total(.cpuUsage, in: DateInterval(start: outsideGap, duration: 60)) != nil)  // sanity: elsewhere works
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
        let today = ReferenceCalendar.calendar.startOfDay(for: Self.end)
        let events = try await p.events(in: DateInterval(start: today, end: Self.end))
        #expect(events.contains { $0.label == "Xcode build" })
        #expect(events.contains { $0.label == "FCP export" })
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

    /// `.restricted` has more positive-CPU apps than a small `limit`, so this only sums to 1 if
    /// `appShares` appends an `.other` remainder for the apps it truncated away.
    @Test func appSharesWithLimitBelowRosterCountStillSumToOneViaOther() async throws {
        let p = MockHistoryProvider(scenario: .restricted, end: Self.end)
        let shares = try await p.appShares(at: Self.end, metric: .cpu, range: .live, limit: 5)
        #expect(shares.count == 6)   // 5 named + `.other`
        #expect(shares.last?.identity.key == .other)
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
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) * 1e-15
        print("thirtyDayQueryIsFast: \(ms) ms for a 30-day/7-metric query (target <20 ms, advisory)")
        // Advisory bound, well above the <20 ms target: report the number above, don't tune to this.
        #expect(elapsed < .milliseconds(100))
    }
}
