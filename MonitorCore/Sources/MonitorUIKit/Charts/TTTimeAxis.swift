import MonitorModel
import os
import SwiftUI

/// DESIGN §2.12 time axis: HStack space-between across the chart width, `micro` `textTertiary`.
/// Label sets: Live "60 s ago · 45 s · 30 s · 15 s · now"; 1H "60 m ago … now"; 24H "24 h ago · 18 h · 12 h ·
/// 6 h · now" on category pages or "00:00 · 04:00 · … · 24:00" (`.clock`, History); 7D 7 short weekdays ending
/// today; 30D 5 "d MMM" dates ending today. Uses the environment's time zone and locale.
public struct TTTimeAxis: View, Equatable {
    public enum Style: Sendable, Equatable { case relative, clock }

    let range: HistoryRange
    let end: Date
    let style: Style
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    public init(range: HistoryRange, end: Date) {
        self.init(range: range, end: end, style: .relative)
    }

    public init(range: HistoryRange, end: Date, style: Style) {
        self.range = range
        self.end = end
        self.style = style
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.range == b.range && a.end == b.end && a.style == b.style
    }

    public nonisolated static func labels(range: HistoryRange, end: Date, style: Style = .relative,
                              timeZone: TimeZone = .current, locale: Locale = .current) -> [String] {
        switch range {
        case .live: return ["60 s ago", "45 s", "30 s", "15 s", "now"]
        case .hour: return ["60 m ago", "45 m", "30 m", "15 m", "now"]
        case .day:
            if style == .clock { return (0...6).map { $0 == 6 ? "24:00" : String(format: "%02d:00", $0 * 4) } }
            return ["24 h ago", "18 h", "12 h", "6 h", "now"]
        case .week:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            return AxisFormatters.format((0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: end) ?? end },
                                         template: "EEE", fixed: false, locale: locale, timeZone: timeZone)
        case .month:
            // DESIGN §2.12 fixed "d MMM" order; month names localized.
            return AxisFormatters.format((0..<5).map { k in end.addingTimeInterval(-30 * 86_400 * Double(4 - k) / 4) },
                                         template: "d MMM", fixed: true, locale: locale, timeZone: timeZone)
        }
    }

    public var body: some View {
        let labels = Self.labels(range: range, end: end, style: style, timeZone: timeZone, locale: locale)
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { i in
                Text(labels[i]).font(TTFont.micro).foregroundStyle(TTColor.textTertiary).lineLimit(1).fixedSize()
                if i < labels.count - 1 { Spacer(minLength: 4) }
            }
        }
    }
}

/// `DateFormatter`s cached per (template, locale, time zone) — never built per render.
enum AxisFormatters {
    private final class Box: @unchecked Sendable {
        var formatters: [String: DateFormatter] = [:]
    }

    private static let lock = OSAllocatedUnfairLock(uncheckedState: Box())

    static func format(_ dates: [Date], template: String, fixed: Bool, locale: Locale, timeZone: TimeZone) -> [String] {
        let key = "\(template)|\(fixed)|\(locale.identifier)|\(timeZone.identifier)"
        return lock.withLockUnchecked { box in
            let f: DateFormatter
            if let cached = box.formatters[key] {
                f = cached
            } else {
                f = DateFormatter()
                f.locale = locale
                f.timeZone = timeZone
                if fixed { f.dateFormat = template } else { f.setLocalizedDateFormatFromTemplate(template) }
                box.formatters[key] = f
            }
            return dates.map(f.string(from:))
        }
    }
}
