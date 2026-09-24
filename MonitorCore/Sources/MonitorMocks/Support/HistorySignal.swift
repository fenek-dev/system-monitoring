import Foundation
import MonitorModel

/// Generates synthetic 30-day history for `MockHistoryProvider`: a pure function of `(metric, date)`
/// (or `(app, metric, date)`), evaluated in O(1) via `SplitMix64` — no sequential replay, no stored
/// arrays, so a query over any window is cheap regardless of how far back it reaches (<20 ms budget).
///
/// The daily shape (quiet overnight, a recurring workday rhythm) and the four named bumps are lifted
/// from `docs/design/artboards/History.dc.html`'s own generator (`__hist`'s `jumps`): "Xcode build"
/// ~14:30, "FCP export" ~12:30, "Dropbox sync" ~09:10, and "Swap +2.1 GB" ~16:05 — replayed every day
/// (dampened on weekends) rather than once, so any point in the range has something to show.
struct HistorySignal {
    let seed: UInt64
    let end: Date
    let calendar: Calendar
    /// The calendar's UTC offset, sampled once at `end` (not per call — see the note above
    /// `epochDay`/`minuteOfDay` below): cheap enough to look up once per query, far too slow to call
    /// per sample when a 30-day query evaluates it 10k+ times.
    private let utcOffsetSeconds: TimeInterval

    /// `.collecting` has just started: coverage is minutes, not 30 days.
    static let collectingCoverage: TimeInterval = 6 * 60
    static let coverageDays = 30
    /// A single paused hour, 5 days back (ARCHITECTURE Wm T2: "gaps (a paused hour)").
    static let pausedGapDaysAgo = 5
    static let pausedGapHour = 3

    init(seed: UInt64, end: Date, calendar: Calendar = .current) {
        self.seed = seed
        self.end = end
        self.calendar = calendar
        self.utcOffsetSeconds = Double(calendar.timeZone.secondsFromGMT(for: end))
    }

    // MARK: - Coverage & gaps

    func coverage(scenario: MockScenario) -> DateInterval {
        if scenario == .collecting {
            return DateInterval(start: end.addingTimeInterval(-Self.collectingCoverage), end: end)
        }
        return DateInterval(start: end.addingTimeInterval(-Double(Self.coverageDays) * 86_400), end: end)
    }

    /// Whole hours are paused, or the point is outside coverage / in the future.
    func isAvailable(at date: Date, scenario: MockScenario) -> Bool {
        guard date <= end, coverage(scenario: scenario).contains(date) else { return false }
        guard scenario != .collecting else { return true }
        let daysAgo = daysAgo(date)
        return !(daysAgo == Self.pausedGapDaysAgo && hour(date) == Self.pausedGapHour)
    }

    // MARK: - System metrics

    func value(_ metric: HistoryMetric, at date: Date, scenario: MockScenario) -> Double? {
        guard isAvailable(at: date, scenario: scenario) else { return nil }
        let minuteOfDay = minuteOfDay(date)
        let dayFraction = Double(minuteOfDay) / 1_440
        let weekendDamping = isWeekend(date) ? 0.5 : 1.0
        let slot = slotIndex(date)

        func demo(_ key: DemoKey, metricSeed: UInt64) -> Double {
            guard let p = DemoSpec.calm[key] else { return 0 }
            let noise = SplitMix64.signed(seed &+ metricSeed, slot) * p.vol * 0.6
            var v = (p.base + noise) * dayDamping(minuteOfDay, night: 0.3) * weekendDamping
            v += bumpContribution(for: key, minuteOfDay: minuteOfDay) * weekendDamping
            return min(max(v, p.min), p.max)
        }

        switch metric {
        case .cpuUsage: return demo(.cpu, metricSeed: 1) / 100
        case .cpuUser: return demo(.cpu, metricSeed: 1) * 0.65 / 100
        case .cpuSystem: return demo(.cpu, metricSeed: 1) * 0.35 / 100
        case .cpuPCluster: return min(1, demo(.cpu, metricSeed: 1) * 1.4 / 100)
        case .cpuECluster: return min(1, demo(.cpu, metricSeed: 1) * 0.6 / 100)
        case .loadAvg1: return 1 + demo(.cpu, metricSeed: 1) / 20
        case .gpuUsage: return demo(.gpu, metricSeed: 2) / 100
        case .gpuFrequency: return demo(.gfreq, metricSeed: 3)
        case .memUsed: return demo(.mem, metricSeed: 4) * 1_073_741_824
        case .memApp: return demo(.mem, metricSeed: 4) * 0.75 * 1_073_741_824
        case .memWired: return demo(.mem, metricSeed: 4) * 0.15 * 1_073_741_824
        case .memCompressed: return demo(.mem, metricSeed: 4) * 0.10 * 1_073_741_824
        case .memPressure: return demo(.press, metricSeed: 5) / 100
        case .swapUsed: return demo(.swap, metricSeed: 6) * 1_073_741_824
        case .netRx: return demo(.netd, metricSeed: 7) * 1_000_000
        case .netTx: return demo(.netu, metricSeed: 8) * 1_000_000
        case .netLatency: return 18 + SplitMix64.signed(seed &+ 9, slot) * 4
        case .diskRead: return demo(.rd, metricSeed: 10) * 1_000_000
        case .diskWrite: return demo(.wr, metricSeed: 11) * 1_000_000
        case .diskReadIOPS: return demo(.rd, metricSeed: 10) * 24
        case .diskWriteIOPS: return demo(.wr, metricSeed: 11) * 23.7
        case .socTemp: return temperature(.temp, metricSeed: 12, minuteOfDay: minuteOfDay, slot: slot, weekend: weekendDamping)
        case .cpuPTemp: return temperature(.tp, metricSeed: 13, minuteOfDay: minuteOfDay, slot: slot, weekend: weekendDamping)
        case .cpuETemp: return temperature(.tp, metricSeed: 13, minuteOfDay: minuteOfDay, slot: slot, weekend: weekendDamping) - 12
        case .gpuTemp: return temperature(.tg, metricSeed: 14, minuteOfDay: minuteOfDay, slot: slot, weekend: weekendDamping)
        case .ssdTemp: return 41 + SplitMix64.signed(seed &+ 15, slot) * 2
        case .batteryTemp: return temperature(.tb, metricSeed: 16, minuteOfDay: minuteOfDay, slot: slot, weekend: weekendDamping)
        case .fan1RPM: return demo(.fan1, metricSeed: 17)
        case .fan2RPM: return demo(.fan2, metricSeed: 18)
        case .packageWatts: return demo(.pwr, metricSeed: 19)
        case .cpuWatts: return demo(.pc, metricSeed: 20)
        case .gpuWatts: return demo(.pg, metricSeed: 21)
        case .aneWatts: return demo(.pa, metricSeed: 22)
        case .dramWatts: return demo(.pd, metricSeed: 23)
        case .systemWatts: return demo(.pwr, metricSeed: 19) * 0.97
        case .batteryPercent: return 40 + 60 * (1 - dayFraction)
        case .thermalPressure:
            let t = temperature(.temp, metricSeed: 12, minuteOfDay: minuteOfDay, slot: slot, weekend: weekendDamping)
            return t >= 90 ? 3 : (t >= 80 ? 2 : (t >= 70 ? 1 : 0))
        }
    }

    // MARK: - App metrics

    func appValue(_ app: DemoApp, _ metric: AppMetric, at date: Date, scenario: MockScenario) -> Double? {
        guard isAvailable(at: date, scenario: scenario) else { return nil }
        let slot = slotIndex(date)
        let damping = dayDamping(minuteOfDay(date), night: 0.35) * (isWeekend(date) ? 0.5 : 1.0)
        func jitter(_ base: Double, _ metricSeed: UInt64) -> Double {
            max(0, (base + SplitMix64.signed(seed &+ UInt64(app.jitterSeed) &+ metricSeed, slot) * base * 0.15) * damping)
        }
        switch metric {
        case .cpu: return jitter(app.baseCPU, 101)
        case .gpu: return jitter(app.baseGPU, 102)
        case .memory: return Double(app.memoryBytes) * (0.85 + 0.3 * SplitMix64.unit(seed &+ UInt64(app.jitterSeed) &+ 103, slot))
        case .netRx: return jitter(app.netRxBps, 104)
        case .netTx: return jitter(app.netTxBps, 105)
        case .diskRead: return jitter(app.diskReadBps, 106)
        case .diskWrite: return jitter(app.diskWriteBps, 107)
        case .energy: return jitter(app.energyWatts, 108)
        }
    }

    // MARK: - Events (the artboard's storyline, replayed every day)

    struct Bump { var label: String; var kind: HistoryEvent.Kind; var minute: Int; var widthMinutes: Double }
    static let bumps: [Bump] = [
        Bump(label: "Xcode build", kind: .runawayApp, minute: 870, widthMinutes: 12.5),
        Bump(label: "FCP export", kind: .appEpisode, minute: 750, widthMinutes: 30),
        Bump(label: "Dropbox sync", kind: .appEpisode, minute: 550, widthMinutes: 25),
        Bump(label: "Swap +2.1 GB", kind: .swapGrowth, minute: 965, widthMinutes: 40),
    ]

    /// Bounded to `coverageDays` iterations regardless of `interval`'s span.
    func events(in interval: DateInterval, scenario: MockScenario) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        let cov = coverage(scenario: scenario)
        guard let clipped = interval.intersection(with: cov) else { return [] }
        var day = calendar.startOfDay(for: clipped.start)
        var guardCount = 0
        while day <= clipped.end, guardCount < Self.coverageDays + 1 {
            guardCount += 1
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? clipped.end.addingTimeInterval(1) }
            for bump in Self.bumps {
                guard let start = calendar.date(byAdding: .minute, value: bump.minute, to: day) else { continue }
                guard start >= clipped.start, start <= clipped.end, start <= end else { continue }
                out.append(HistoryEvent(kind: bump.kind, start: start,
                                         end: start.addingTimeInterval(bump.widthMinutes * 60),
                                         level: .elevated, label: bump.label))
            }
            if daysAgo(day) == Self.pausedGapDaysAgo, let gapStart = calendar.date(bySettingHour: Self.pausedGapHour, minute: 0, second: 0, of: day),
               gapStart >= clipped.start, gapStart <= clipped.end {
                out.append(HistoryEvent(kind: .samplingPaused, start: gapStart, end: gapStart.addingTimeInterval(3_600),
                                         level: .calm, label: "Paused"))
            }
        }
        return out
    }

    // MARK: - Helpers

    private func temperature(_ key: DemoKey, metricSeed: UInt64, minuteOfDay: Int, slot: Int, weekend: Double) -> Double {
        guard let p = DemoSpec.calm[key] else { return 0 }
        let noise = SplitMix64.signed(seed &+ metricSeed, slot) * p.vol * 0.6
        var v = p.base + noise + bumpContribution(for: key, minuteOfDay: minuteOfDay) * weekend
        let isNight = minuteOfDay < 450 || minuteOfDay > 1_350
        if isNight { v = 38 + (v - 38) * 0.45 }
        return min(max(v, p.min), p.max)
    }

    /// Overnight (before 07:30 / after 22:30) activity is damped toward `night` × base.
    private func dayDamping(_ minuteOfDay: Int, night: Double) -> Double {
        (minuteOfDay < 450 || minuteOfDay > 1_350) ? night : 1.0
    }

    /// Gaussian bumps at the artboard's event times, added to the relevant metrics only.
    private func bumpContribution(for key: DemoKey, minuteOfDay: Int) -> Double {
        func gaussian(_ center: Int, _ width: Double, _ amplitude: Double) -> Double {
            let x = Double(minuteOfDay - center) / (width * 5)   // widthMinutes ≈ width buckets × 5
            return amplitude * exp(-x * x)
        }
        switch key {
        case .cpu: return gaussian(870, 2.5, 58) + gaussian(750, 6, 18)
        case .temp, .tp: return gaussian(870, 3.5, 14) + gaussian(750, 6, 6)
        case .pwr: return gaussian(870, 2.5, 22) + gaussian(750, 6, 9)
        case .gpu: return gaussian(750, 6, 48)
        case .netd: return gaussian(550, 5, 22)
        case .press: return gaussian(965, 8, 30)
        default: return 0
        }
    }

    // These deliberately avoid per-call `Calendar` lookups (tens of microseconds each, and
    // `value(_:at:scenario:)` calls several of these per sample — easily 10k+ calls for a 30-day query,
    // which is what actually has to clear the <20 ms budget): plain arithmetic shifted by the UTC offset
    // sampled once in `init`, so "day"/"minute of day" still land on local calendar days. `events(in:
    // scenario:)` runs far less often and still uses `calendar` for calendar-correct iteration.

    private static let secondsPerDay: TimeInterval = 86_400

    private func epochDay(_ date: Date) -> Int {
        Int(((date.timeIntervalSince1970 + utcOffsetSeconds) / Self.secondsPerDay).rounded(.down))
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let secs = (date.timeIntervalSince1970 + utcOffsetSeconds).truncatingRemainder(dividingBy: Self.secondsPerDay)
        return Int((secs < 0 ? secs + Self.secondsPerDay : secs) / 60)
    }

    private func hour(_ date: Date) -> Int { minuteOfDay(date) / 60 }

    private func daysAgo(_ date: Date) -> Int { epochDay(end) - epochDay(date) }

    /// Jan 1 1970 (epoch day 0) was a Thursday; Sunday/Saturday (weekday 0/6 in that indexing) are weekends.
    private func isWeekend(_ date: Date) -> Bool {
        let weekday = ((epochDay(date) + 4) % 7 + 7) % 7
        return weekday == 0 || weekday == 6
    }

    /// A 5-minute slot index since the Unix epoch — coarse enough to look smooth, fine enough that
    /// nearby points are still independent samples.
    private func slotIndex(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 300)
    }
}
