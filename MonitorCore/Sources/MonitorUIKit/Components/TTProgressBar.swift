import MonitorModel
import SwiftUI

/// DESIGN §2.16 single-value bars.
/// - `thin`: height 5, radius 2.5, track `separator` (media engines, sensor rows) — default.
/// - `medium`: height 8, radius 4, track `fillFree` (Overview disk card).
/// `thresholds` (ascending) switch the fill to the level color once `value ≥ threshold`. nil value → empty track.
public struct TTProgressBar: View, Equatable {
    public enum Style: Sendable, Equatable { case thin, medium }

    let value: Double?
    let tint: Color
    let thresholds: [Double]
    let levels: [AlertLevel]
    let style: Style

    public init(value: Double?, tint: Color, thresholds: [(Double, AlertLevel)] = []) {
        self.init(value: value, tint: tint, thresholds: thresholds, style: .thin)
    }

    public init(value: Double?, tint: Color, thresholds: [(Double, AlertLevel)] = [], style: Style) {
        self.value = value
        self.tint = tint
        self.thresholds = thresholds.map(\.0)
        levels = thresholds.map(\.1)
        self.style = style
    }

    var fillColor: Color {
        guard let value else { return tint }
        var color = tint
        for (t, l) in zip(thresholds, levels) where value >= t && l != .calm { color = TTColor.level(l) }
        return color
    }

    public var body: some View {
        let h: CGFloat = style == .thin ? 5 : 8
        let track = style == .thin ? TTColor.separator : TTColor.fillFree
        let fraction = min(max(value ?? 0, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if value != nil {
                    Capsule().fill(fillColor).frame(width: geo.size.width * fraction)
                }
            }
        }
        .frame(height: h)
        .accessibilityValue(value.map { TTFormat.percent($0) } ?? "unavailable")
    }
}

/// DESIGN §2.16 multi-segment bars: `split` (power, h 8 r 4 gap 2), `composition` (memory, h 18 r 5 gap 2),
/// `volume` (h 10 r 5 gap 2, track `fillFree`). Segments are fractions of the whole, left to right; the bar
/// is clipped to its radius. `remainder` fills what's left (e.g. `fillRest`, `fillFree`); otherwise the
/// track shows through.
public struct TTSegmentBar: View, Equatable {
    public struct Segment: Equatable, Sendable {
        public var fraction: Double
        public var color: Color
        public init(_ fraction: Double, _ color: Color) {
            self.fraction = fraction
            self.color = color
        }
    }

    public enum Style: Sendable, Equatable { case split, composition, volume }

    let segments: [Segment]
    let style: Style
    let remainder: Color?

    public init(_ segments: [Segment], style: Style, remainder: Color? = nil) {
        self.segments = segments
        self.style = style
        self.remainder = remainder
    }

    var height: CGFloat { style == .split ? 8 : (style == .composition ? 18 : 10) }
    var radius: CGFloat { style == .split ? TTRadius.r4 : TTRadius.r5 }

    /// Segment widths for `width` with 2-pt gaps between visible segments (a remainder counts as a segment).
    static func widths(_ fractions: [Double], remainder: Bool, width: CGFloat, gap: CGFloat) -> [CGFloat] {
        var f = fractions.map { max(0, $0) }
        let used = f.reduce(0, +)
        if remainder { f.append(max(0, 1 - used)) }
        let visible = f.filter { $0 > 0 }.count
        let available = max(0, width - gap * CGFloat(max(0, visible - 1)))
        let total = max(f.reduce(0, +), remainder ? 1 : 1)
        return f.map { $0 > 0 ? available * CGFloat($0 / total) : 0 }
    }

    public var body: some View {
        GeometryReader { geo in
            let widths = Self.widths(segments.map(\.fraction), remainder: remainder != nil, width: geo.size.width, gap: 2)
            let colors = segments.map(\.color) + (remainder.map { [$0] } ?? [])
            HStack(spacing: 0) {
                ForEach(widths.indices, id: \.self) { i in
                    if widths[i] > 0 {
                        Rectangle().fill(colors[i]).frame(width: widths[i])
                        if widths[(i + 1)...].contains(where: { $0 > 0 }) {
                            Color.clear.frame(width: 2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(style == .volume ? TTColor.fillFree : .clear)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// DESIGN §2.16 `thermalScale`: 4 equal columns (gap 6); bar 6 tall r 3 in the level color (1 when current,
/// 0.28 otherwise); label `body12` (semibold `textPrimary` when current); description `caption` `textTertiary`.
public struct TTThermalScale: View, Equatable {
    public struct Level: Equatable, Sendable {
        public var title: String, detail: String, color: Color
        public init(title: String, detail: String, color: Color) {
            self.title = title
            self.detail = detail
            self.color = color
        }
    }

    let levels: [Level]
    let current: Int?

    public init(levels: [Level], current: Int?) {
        self.levels = levels
        self.current = current
    }

    public var body: some View {
        HStack(alignment: .top, spacing: TTSpace.x6) {
            ForEach(levels.indices, id: \.self) { i in
                let on = i == current
                VStack(alignment: .leading, spacing: TTSpace.x6) {
                    RoundedRectangle(cornerRadius: TTRadius.r3).fill(levels[i].color.opacity(on ? 1 : 0.28)).frame(height: 6)
                    Text(levels[i].title)
                        .font(on ? TTFont.body12Strong : TTFont.body12)
                        .foregroundStyle(on ? TTColor.textPrimary : TTColor.textSecondary)
                    Text(levels[i].detail).font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
