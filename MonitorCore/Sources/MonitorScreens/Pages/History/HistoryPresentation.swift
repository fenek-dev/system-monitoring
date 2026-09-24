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

    /// Timeline card title: "Last 60 seconds", "Last hour", "Thursday, 24 September" (locale-ordered
    /// `EEEE d MMMM`, §5.8), "18 – 24 September", "26 August – 24 September".
    public static func title(_ window: HistoryWindow, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        switch window.range {
        case .live: return "Last 60 seconds"
        case .hour: return "Last hour"
        case .day:
            // Reference/DESIGN copy: "Thursday, 24 September" (fixed day-first order; names localized).
            return formatter(fixed: "EEEE, d MMMM", locale, timeZone).string(from: now)
        case .week, .month:
            let first = window.start
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let sameMonth = cal.component(.month, from: first) == cal.component(.month, from: now)
            let dayOnly = formatter(fixed: "d", locale, timeZone)
            let dayMonth = formatter(fixed: "d MMMM", locale, timeZone)
            // "18 – 24 September" / "26 August – 24 September".
            let lhs = sameMonth ? dayOnly.string(from: first) : dayMonth.string(from: first)
            return "\(lhs) – \(dayMonth.string(from: now))"
        }
    }

    private static func formatter(fixed format: String, _ locale: Locale, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = tz
        f.dateFormat = format
        return f
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

    /// Chip label "{title} · HH:mm".
    public static func chipLabel(_ e: HistoryEvent, timeZone: TimeZone) -> String {
        "\(eventTitle(e)) · \(TTFormat.clock(e.start, timeZone: timeZone))"
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
    public static func note(_ events: [HistoryEvent], at time: Date, bucket: TimeInterval, now: Date) -> String {
        let slot = DateInterval(start: time, duration: max(bucket, 1))
        let hits = events.filter { e in
            let end = max(e.end ?? now, e.start.addingTimeInterval(1))
            return DateInterval(start: e.start, end: end).intersects(slot)
        }
        guard !hits.isEmpty else { return "Nothing unusual in this window." }
        let sentences = hits.sorted { $0.level != $1.level ? $0.level > $1.level : $0.start < $1.start }.map { e in
            switch e.kind {
            case .thermalPressure: "Thermal pressure went to \(pressureName(e))."
            case .memoryPressure: "Memory pressure reached \(e.level == .critical ? "Critical" : "Warning")."
            case .runawayApp: "CPU spike from \(e.app.map { $0.displayName } ?? eventTitle(e))."
            case .appEpisode, .swapGrowth: "\(eventTitle(e))."
            case .samplingPaused: "Sampling was paused."
            case .systemSleep: "The Mac was asleep."
            }
        }
        return sentences.joined(separator: " ")
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

    public static let height: CGFloat = 22
    public static let plusWidth: CGFloat = 30

    /// `measure`: text width of a label in `caption` (chip width = text + 16 padding + 2 border).
    public static func layout(_ events: [HistoryEvent], window: HistoryWindow, width: CGFloat,
                              label: (HistoryEvent) -> String, measure: (String) -> CGFloat) -> [HistoryChip] {
        let visible = events.filter { $0.kind != .samplingPaused && $0.start >= window.start && $0.start <= window.end }
        let ranked = visible.sorted { $0.level != $1.level ? $0.level > $1.level : $0.start < $1.start }
        var placed: [HistoryChip] = []
        for e in ranked {
            let text = label(e)
            let w = ceil(measure(text)) + 18
            let center = CGFloat(window.fraction(of: e.start)) * width
            let x = min(max(center, w / 2), max(width - w / 2, w / 2))
            if let i = placed.firstIndex(where: { abs($0.x - x) < ($0.width + w) / 2 + ($0.hidden > 0 ? plusWidth : 0) }) {
                placed[i].hidden += 1
            } else {
                placed.append(HistoryChip(id: e.id, event: e, text: text, x: x, width: w, hidden: 0))
            }
        }
        return placed.sorted { $0.x < $1.x }
    }
}

/// Band kinds shown on the lanes and in the legend.
public enum HistoryBandKind: Hashable, Sendable, CaseIterable {
    case fair, serious, critical, memory, paused

    public var legend: String {
        switch self {
        case .fair: "Thermal pressure: Fair"
        case .serious: "Thermal pressure: Serious"
        case .critical: "Thermal pressure: Critical"
        case .memory: "Memory pressure"
        case .paused: "Paused"
        }
    }

    public var fill: Color {
        switch self {
        case .fair, .memory: TTColor.statusElevated.opacity(0.14)
        case .serious: TTColor.statusElevated.opacity(0.22)
        case .critical: TTColor.statusCritical.opacity(0.14)
        case .paused: TTColor.fillTrack
        }
    }

    public var swatch: Color {
        switch self {
        case .fair, .serious, .memory: TTColor.statusElevatedSwatch
        case .critical: TTColor.statusCriticalSwatch
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
        case .memoryPressure: return .memory
        case .samplingPaused, .systemSleep: return .paused
        default: return nil
        }
    }
}

public struct HistoryBand: Equatable, Sendable {
    public var kind: HistoryBandKind
    public var x0: CGFloat
    public var x1: CGFloat

    public static func layout(_ events: [HistoryEvent], window: HistoryWindow, width: CGFloat, now: Date) -> [HistoryBand] {
        events.compactMap { e in
            guard let kind = HistoryBandKind.of(e) else { return nil }
            let end = e.end ?? now
            guard end > window.start, e.start < window.end else { return nil }
            let x0 = CGFloat(window.fraction(of: e.start)) * width
            let x1 = CGFloat(window.fraction(of: end)) * width
            return HistoryBand(kind: kind, x0: x0, x1: max(x1, x0 + 1))
        }
    }
}
