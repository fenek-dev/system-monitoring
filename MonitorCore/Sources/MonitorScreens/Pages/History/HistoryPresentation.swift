import Foundation
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Pure copy / geometry for the History page (DESIGN §3.13), tested in `HistoryModelTests`.
public enum HistoryText {
    /// "Stored locally · 5-minute resolution for 24 h · kept for 30 days" (design copy at 24H).
    public static func subtitle(_ range: HistoryRange) -> String {
        let middle = switch range {
        case .live: "1-second resolution for 60 s"
        case .hour: "15-second resolution for 1 h"
        case .day: "5-minute resolution for 24 h"
        case .week: "30-minute resolution for 7 d"
        case .month: "2-hour resolution for 30 d"
        }
        return "Stored locally · \(middle) · kept for 30 days"
    }

    /// Timeline card title: "Last 60 seconds", "Last hour", "Thursday, 24 September" (reference copy, fixed
    /// day-first order, names localized), "18 – 24 September", "26 August – 24 September". `calendar` is the
    /// model's (one source of truth for time zone and locale).
    public static func title(_ window: HistoryWindow, now: Date, calendar: Calendar) -> String {
        switch window.range {
        case .live: return "Last 60 seconds"
        case .hour: return "Last hour"
        case .day:
            return formatter(fixed: "EEEE, d MMMM", calendar).string(from: now)
        case .week, .month:
            let first = window.firstDay(calendar)
            let sameMonth = calendar.component(.month, from: first) == calendar.component(.month, from: now)
            let dayOnly = formatter(fixed: "d", calendar)
            let dayMonth = formatter(fixed: "d MMMM", calendar)
            let lhs = sameMonth ? dayOnly.string(from: first) : dayMonth.string(from: first)
            return "\(lhs) – \(dayMonth.string(from: now))"
        }
    }

    static let formatterCacheCap = 32

    /// Formatters cached on this thread (tests).
    static var cachedFormatterCount: Int {
        Thread.current.threadDictionary.allKeys.compactMap { $0 as? String }.filter { $0.hasPrefix("tt.history.df|") }
            .count
    }

    /// Cached per (format, calendar) — per thread, since `DateFormatter` isn't Sendable; capped at 32 entries.
    static func formatter(fixed format: String, _ calendar: Calendar) -> DateFormatter {
        let locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        let key = "tt.history.df|\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(locale.identifier)"
        let cache = Thread.current.threadDictionary
        if let f = cache[key] as? DateFormatter { return f }
        // Bounded: time zone/locale changes mint new keys; drop our entries past the cap.
        let ours = cache.allKeys.compactMap { $0 as? String }.filter { $0.hasPrefix("tt.history.df|") }
        if ours.count >= formatterCacheCap { ours.forEach { cache.removeObject(forKey: $0) } }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        cache[key] = f
        return f
    }

    /// A moment on the History page: "14:35"; on 7D/30D with the weekday, "Tue 09:10" (ruling).
    public static func moment(_ date: Date, range: HistoryRange, calendar: Calendar) -> String {
        switch range {
        case .week, .month: formatter(fixed: "EEE HH:mm", calendar).string(from: date)
        default: formatter(fixed: "HH:mm", calendar).string(from: date)
        }
    }

    /// Lane value at the cursor (§5): integer %, rates by §5.4 bands, °C/°F, 1-decimal W.
    public static func laneValue(_ metric: HistoryMetric, _ v: Double?, units: UnitPreferences) -> String? {
        guard let v else { return nil }
        switch metric {
        case .cpuUsage, .gpuUsage, .memPressure: return TTFormat.percent(v)
        case .netRx, .netTx: return TTFormat.rate(v, units: units)
        case .socTemp: return TTFormat.temperature(v, units: units)
        case .packageWatts: return TTFormat.watts(v)
        default: return TTFormat.number(v, digits: 1)
        }
    }

    /// "Xcode · 812% CPU".
    public static func topProcess(_ share: AppShare?, metric: TreemapMetric, units: UnitPreferences) -> String? {
        guard let share else { return nil }
        let value: String = switch metric {
        case .cpu: TTFormat.cpuPercentInteger(share.value) + " CPU"
        case .gpu: TTFormat.cpuPercentInteger(share.value) + " GPU"
        case .memory: TTFormat.bytes(UInt64(max(0, share.value)))
        case .network: TTFormat.rate(share.value, units: units)
        case .disk: TTFormat.diskRate(share.value)
        case .energy: TTFormat.appWatts(share.value)
        }
        return "\(share.identity.displayName) · \(value)"
    }

    /// Chip label "{title} · HH:mm" ("{title} · Tue 09:10" on 7D/30D).
    public static func chipLabel(_ e: HistoryEvent, range: HistoryRange, calendar: Calendar) -> String {
        "\(eventTitle(e)) · \(moment(e.start, range: range, calendar: calendar))"
    }

    public static func eventTitle(_ e: HistoryEvent) -> String {
        if !e.label.isEmpty { return e.label }
        switch e.kind {
        case .thermalPressure: return "Thermal: \(pressureName(e))"
        case .memoryPressure: return "Memory: \(e.level == .critical ? "Critical" : "Warning")"
        case .runawayApp: return "\(e.app?.displayName ?? "App") CPU spike"
        case .appEpisode: return e.app?.displayName ?? "Activity"
        case .swapGrowth: return "Swap growth"
        case .samplingPaused: return "Sampling paused"
        case .systemSleep: return "Sleep"
        }
    }

    static func pressureName(_ e: HistoryEvent) -> String {
        if let p = e.peak.flatMap({ ThermalPressure(rawValue: Int($0)) }) {
            switch p {
            case .nominal: return "Nominal"
            case .fair: return "Fair"
            case .serious: return "Serious"
            case .critical: return "Critical"
            }
        }
        return e.level == .critical ? "Serious" : "Fair"
    }

    /// Note for the events overlapping the cursor bucket (≤ 3 lines), else "Nothing unusual in this window."
    /// Design copy: "CPU spike from an Xcode build. SoC reached 88°C; thermal pressure went to Fair."
    /// - openEnd: end used for ongoing events (the window's newest bucket, never the ticking clock).
    /// - socPeak: SoC temperature peak over an interval (°C), for the thermal sentence.
    public static func note(_ events: [HistoryEvent], at time: Date, bucket: TimeInterval, openEnd: Date,
                            units: UnitPreferences = UnitPreferences(),
                            socPeak: (DateInterval) -> Double? = { _ in nil }) -> String {
        let slot = DateInterval(start: time, duration: max(bucket, 1))
        let hits = events.filter { e in
            let end = max(e.end ?? openEnd, e.start.addingTimeInterval(1))
            return DateInterval(start: e.start, end: end).intersects(slot)
        }
        guard !hits.isEmpty else { return "Nothing unusual in this window." }
        let ordered = hits.sorted { a, b in
            // Culprit first (the design reads "CPU spike …. SoC reached …"), then by severity and time.
            let ra = a.kind == .runawayApp ? 0 : 1, rb = b.kind == .runawayApp ? 0 : 1
            if ra != rb { return ra < rb }
            return a.level != b.level ? a.level > b.level : a.start < b.start
        }
        let sentences = ordered.map { e -> String in
            switch e.kind {
            case .thermalPressure:
                let end = max(e.end ?? openEnd, e.start.addingTimeInterval(1))
                if let peak = socPeak(DateInterval(start: e.start, end: end)) {
                    return "SoC reached \(TTFormat.temperature(peak, units: units)); thermal pressure went to \(pressureName(e))."
                }
                return "Thermal pressure went to \(pressureName(e))."
            case .memoryPressure: return "Memory pressure reached \(e.level == .critical ? "Critical" : "Warning")."
            case .runawayApp:
                if !e.label.isEmpty { return "CPU spike from \(article(e.label)) \(e.label)." }
                return "CPU spike from \(e.app?.displayName ?? "an app")."
            case .appEpisode, .swapGrowth: return "\(eventTitle(e))."
            case .samplingPaused: return "Sampling was paused."
            case .systemSleep: return "The Mac was asleep."
            }
        }
        return sentences.joined(separator: " ")
    }

    /// "a"/"an" by the first letter's sound ("an Xcode build").
    static func article(_ phrase: String) -> String {
        guard let c = phrase.first?.lowercased().first else { return "a" }
        return "aeiox".contains(c) ? "an" : "a"
    }

    /// ARCHITECTURE §6 banner when the store could not be opened (in-memory history keeps working).
    public static func persistenceBanner(persistent: Bool) -> String? {
        persistent ? nil : "History isn’t being saved — the history database could not be opened; this session is kept in memory only."
    }

    /// Axis labels for stored ranges, positioned by `window.fraction` (DESIGN §2.12): 24H `00:00 … 24:00` every 4 h,
    /// 7D the 7 day starts as short weekdays (today last), 30D 5 day starts `d MMM` a week apart ending today.
    /// Live/1H: nil (relative `TTTimeAxis`).
    public static func axisLabels(_ window: HistoryWindow, calendar: Calendar) -> [(text: String, fraction: Double)]? {
        func f(_ format: String) -> DateFormatter { formatter(fixed: format, calendar) }
        let first = window.firstDay(calendar)
        func day(_ i: Int) -> Date { calendar.date(byAdding: .day, value: i, to: first) ?? first }
        switch window.range {
        case .live, .hour:
            return nil
        case .day:
            return (0...6).map { k in
                let t = first.addingTimeInterval(Double(k) * 4 * 3_600)
                return (String(format: "%02d:00", k * 4), k == 6 ? 1 : window.fraction(of: t))
            }
        case .week:
            let wd = f("EEE")
            return (0..<7).map { i in (wd.string(from: day(i)), window.fraction(of: day(i))) }
        case .month:
            let dm = f("d MMM")
            return [1, 8, 15, 22, 29].map { i in (dm.string(from: day(i)), window.fraction(of: day(i))) }
        }
    }
}

/// History lanes (DESIGN §3.13): label, icon, color, y-domain.
public struct HistoryLane: Identifiable, Sendable {
    public var id: HistoryMetric { metric }
    public var metric: HistoryMetric
    public var label: String
    public var icon: TTIconName

    public static let all: [HistoryLane] = [
        HistoryLane(metric: .cpuUsage, label: "CPU", icon: .cpu),
        HistoryLane(metric: .gpuUsage, label: "GPU", icon: .gpu),
        HistoryLane(metric: .memPressure, label: "Memory pressure", icon: .memory),
        HistoryLane(metric: .netRx, label: "Network ↓", icon: .network),
        HistoryLane(metric: .socTemp, label: "SoC temperature", icon: .thermals),
        HistoryLane(metric: .packageWatts, label: "Package power", icon: .power),
    ]

    public var color: Color {
        switch metric {
        case .cpuUsage: TTColor.cpu
        case .gpuUsage: TTColor.gpu
        case .memPressure: TTColor.mem
        case .netRx: TTColor.net
        case .socTemp: TTColor.thermal
        default: TTColor.power
        }
    }

    /// CPU/GPU/Memory 0–100 %, Network 0–auto, Temp 35–100 °C, Power 0–auto (≥ 1 W).
    public func domain(_ values: [Double?]) -> ClosedRange<Double> {
        let top = values.compactMap { $0 }.max() ?? 0
        switch metric {
        case .cpuUsage, .gpuUsage, .memPressure: return 0...1
        case .netRx: return 0...TTFormat.niceRateCeiling(top)
        case .socTemp: return 35...100
        default: return 0...TTFormat.niceCeiling(top, minimum: 1)
        }
    }
}

/// Event chips positioned at the event's x; overlapping chips keep the most severe and collapse the rest into
/// "+n" (DESIGN §3.13).
public struct HistoryChip: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var event: HistoryEvent
    public var text: String
    public var x: CGFloat
    public var width: CGFloat
    /// Hidden overlapping chips folded into this one ("+n").
    public var hidden: Int
    /// Width of the "+n" pill (0 when nothing is hidden).
    public var pillWidth: CGFloat = 0

    public static let height: CGFloat = 22
    /// Gap between a chip and its "+n" pill, and the minimum gap between chip groups.
    public static let gap: CGFloat = 4

    /// Chip + pill extent to the right of the chip's centre.
    public var right: CGFloat { x + width / 2 + (hidden > 0 ? Self.gap + pillWidth : 0) }
    public var left: CGFloat { x - width / 2 }

    /// `measure`: text width in `caption` (chip width = text + 16 padding + 2 border; the "+n" pill likewise).
    /// Placement accounts for the "+n" pills: groups (chip + pill) never overlap or touch closer than `gap`.
    public static func layout(_ events: [HistoryEvent], window: HistoryWindow, width: CGFloat,
                              label: (HistoryEvent) -> String, measure: (String) -> CGFloat) -> [HistoryChip] {
        let visible = events.filter { $0.kind != .samplingPaused && $0.start >= window.start && $0.start <= window.end }
        let ranked = visible.sorted { $0.level != $1.level ? $0.level > $1.level : $0.start < $1.start }
        func pill(_ n: Int) -> CGFloat { n > 0 ? ceil(measure("+\(n)")) + 18 : 0 }
        var placed: [HistoryChip] = []
        for e in ranked {
            let text = label(e)
            let w = ceil(measure(text)) + 18
            let center = CGFloat(window.fraction(of: e.start)) * width
            let x = min(max(center, w / 2), max(width - w / 2, w / 2))
            let l = x - w / 2, r = x + w / 2
            if let i = placed.firstIndex(where: { l < $0.right + gap && r + gap > $0.left }) {
                placed[i].hidden += 1
                placed[i].pillWidth = pill(placed[i].hidden)
            } else {
                placed.append(HistoryChip(id: e.id, event: e, text: text, x: x, width: w, hidden: 0))
            }
        }
        // A pill that grew after later chips were placed may now reach the next group: fold that group into the
        // more severe (then earlier) of the two until every neighbour clears.
        placed.sort { $0.x < $1.x }
        var i = 0
        while i + 1 < placed.count {
            let a = placed[i], b = placed[i + 1]
            guard a.right + gap > b.left else {
                i += 1
                continue
            }
            let keepA = a.event.level != b.event.level ? a.event.level > b.event.level : a.event.start <= b.event.start
            var kept = keepA ? a : b
            kept.hidden = a.hidden + b.hidden + 1
            kept.pillWidth = pill(kept.hidden)
            placed.replaceSubrange(i...(i + 1), with: [kept])
            i = max(0, i - 1)
        }
        return settle(placed, width: width, fold: { a, b in
            let keepA = a.event.level != b.event.level ? a.event.level > b.event.level : a.event.start <= b.event.start
            var kept = keepA ? a : b
            kept.hidden = a.hidden + b.hidden + 1
            kept.pillWidth = pill(kept.hidden)
            return kept
        })
    }

    /// Total width of chip + "+n" pill.
    public var groupWidth: CGFloat { width + (hidden > 0 ? Self.gap + pillWidth : 0) }

    /// Keeps every chip + pill group inside [0, width] as a sequence: groups that don't fit together are folded,
    /// then a forward pass pushes groups right of their left neighbour and a backward pass pulls them inside the
    /// right edge and left of their right neighbour. `x` stays the chip's centre.
    static func settle(_ chips: [HistoryChip], width: CGFloat, fold: (HistoryChip, HistoryChip) -> HistoryChip)
        -> [HistoryChip] {
        var out = chips.sorted { $0.x < $1.x }
        func total() -> CGFloat { out.reduce(0) { $0 + $1.groupWidth } + gap * CGFloat(max(0, out.count - 1)) }
        while out.count > 1 && total() > width {
            // Fold the tightest neighbours first.
            let i = (0..<(out.count - 1)).min { out[$0 + 1].left - out[$0].right < out[$1 + 1].left - out[$1].right } ?? 0
            out.replaceSubrange(i...(i + 1), with: [fold(out[i], out[i + 1])])
        }
        var lefts = out.map(\.left)
        for i in lefts.indices {
            let floor = i == 0 ? 0 : lefts[i - 1] + out[i - 1].groupWidth + gap
            lefts[i] = max(lefts[i], floor)
        }
        for i in lefts.indices.reversed() {
            let ceiling = i == lefts.count - 1 ? width : lefts[i + 1] - gap
            lefts[i] = min(lefts[i], ceiling - out[i].groupWidth)
        }
        for i in out.indices { out[i].x = lefts[i] + out[i].width / 2 }
        return out
    }
}

/// Band kinds shown on the lanes and in the legend (DESIGN §3.13; ICR-12 memory levels).
public enum HistoryBandKind: Hashable, Sendable, CaseIterable {
    case fair, serious, critical, memory, memoryCritical, paused

    public var legend: String {
        switch self {
        case .fair: "Thermal pressure: Fair"
        case .serious: "Thermal pressure: Serious"
        case .critical: "Thermal pressure: Critical"
        case .memory: "Memory pressure"
        case .memoryCritical: "Memory pressure: Critical"
        case .paused: "Paused"
        }
    }

    public var fill: Color {
        switch self {
        case .fair, .memory: TTColor.statusElevated.opacity(0.14)
        case .serious: TTColor.statusElevated.opacity(0.22)
        case .critical, .memoryCritical: TTColor.statusCritical.opacity(0.14)
        case .paused: TTColor.fillTrack
        }
    }

    public var swatch: Color {
        switch self {
        case .fair, .serious, .memory: TTColor.statusElevatedSwatch
        case .critical, .memoryCritical: TTColor.statusCriticalSwatch
        case .paused: TTColor.fillTrack
        }
    }

    public static func of(_ e: HistoryEvent) -> HistoryBandKind? {
        switch e.kind {
        case .thermalPressure:
            switch HistoryText.pressureName(e) {
            case "Serious": return .serious
            case "Critical": return .critical
            default: return .fair
            }
        case .memoryPressure: return e.level == .critical ? .memoryCritical : .memory
        case .samplingPaused, .systemSleep: return .paused
        default: return nil
        }
    }

    /// ICR-12 `memPressureLevel` bucket average: > 2.5 critical, > 1.0 warning.
    public static func memory(level: Double?) -> HistoryBandKind? {
        guard let level else { return nil }
        if level > 2.5 { return .memoryCritical }
        if level > 1.0 { return .memory }
        return nil
    }
}

public struct HistoryBand: Equatable, Sendable {
    public var kind: HistoryBandKind
    public var x0: CGFloat
    public var x1: CGFloat

    /// Thermal/paused bands from events; memory bands from the ICR-12 level series when it has values (runs of
    /// warning/critical buckets), else from memory-pressure events. `openEnd` closes ongoing events.
    public static func layout(_ events: [HistoryEvent], memoryLevels: [Double?], window: HistoryWindow, width: CGFloat,
                              openEnd: Date) -> [HistoryBand] {
        let useSeries = memoryLevels.contains { $0 != nil }
        var out: [HistoryBand] = []
        let step = window.count > 1 ? width / CGFloat(window.count - 1) : width
        for e in events {
            guard let kind = HistoryBandKind.of(e) else { continue }
            let end = e.end ?? openEnd
            guard end > window.start, e.start < window.end else { continue }
            let isMemory = kind == .memory || kind == .memoryCritical
            if useSeries && isMemory {
                // The level series wins wherever it classifies a bucket; an ongoing episode only fills the
                // buckets the store hasn't classified yet (nil), so nothing is drawn twice.
                guard e.end == nil else { continue }
                let a = window.index(of: e.start), b = window.index(of: end)
                var i = a
                while i <= b {
                    guard i < memoryLevels.count, memoryLevels[i] != nil else {
                        var j = i
                        while j + 1 <= b && (j + 1 >= memoryLevels.count || memoryLevels[j + 1] == nil) { j += 1 }
                        let x0 = max(0, CGFloat(i) * step - step / 2), x1 = min(width, CGFloat(j) * step + step / 2)
                        out.append(HistoryBand(kind: kind, x0: x0, x1: max(x1, x0 + 1)))
                        i = j + 1
                        continue
                    }
                    i += 1
                }
                continue
            }
            let x0 = CGFloat(window.fraction(of: e.start)) * width
            let x1 = CGFloat(window.fraction(of: end)) * width
            out.append(HistoryBand(kind: kind, x0: x0, x1: max(x1, x0 + 1)))
        }
        if useSeries, window.count > 1 {
            var runStart: Int?
            var runKind: HistoryBandKind?
            func close(_ end: Int) {
                guard let s = runStart, let k = runKind else { return }
                let x0 = max(0, CGFloat(s) * step - step / 2), x1 = min(width, CGFloat(end) * step + step / 2)
                out.append(HistoryBand(kind: k, x0: x0, x1: max(x1, x0 + 1)))
            }
            for i in 0..<min(memoryLevels.count, window.count) {
                let k = HistoryBandKind.memory(level: memoryLevels[i])
                if k != runKind {
                    close(i - 1)
                    runStart = k == nil ? nil : i
                    runKind = k
                }
            }
            close(min(memoryLevels.count, window.count) - 1)
        }
        return out
    }
}

