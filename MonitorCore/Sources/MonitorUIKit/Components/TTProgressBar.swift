import MonitorModel
import SwiftUI

/// DESIGN §2.16 single-value bars (Canvas, no GeometryReader).
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
    let label: String?

    public init(value: Double?, tint: Color, thresholds: [(Double, AlertLevel)] = []) {
        self.init(value: value, tint: tint, thresholds: thresholds, style: .thin)
    }

    public init(value: Double?, tint: Color, thresholds: [(Double, AlertLevel)] = [], style: Style, label: String? = nil) {
        self.value = value
        self.tint = tint
        self.thresholds = thresholds.map(\.0)
        levels = thresholds.map(\.1)
        self.style = style
        self.label = label
    }

    /// Fill color: the highest non-calm level whose threshold `value` reaches, else `tint`.
    nonisolated static func fillColor(value: Double?, tint: Color, thresholds: [(Double, AlertLevel)]) -> Color {
        guard let value else { return tint }
        var color = tint
        for (t, l) in thresholds where value >= t && l != .calm { color = TTColor.level(l) }
        return color
    }

    public var body: some View {
        let h: CGFloat = style == .thin ? 5 : 8
        let track = style == .thin ? TTColor.separator : TTColor.fillFree
        let fraction = min(max(value ?? 0, 0), 1)
        let fill = Self.fillColor(value: value, tint: tint, thresholds: Array(zip(thresholds, levels)))
        let hasValue = value != nil
        Canvas { ctx, size in
            let r = size.height / 2
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r), with: .color(track))
            if hasValue, fraction > 0 {
                let w = max(size.width * fraction, size.height)
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: min(w, size.width), height: size.height), cornerRadius: r),
                         with: .color(fill))
            }
        }
        .frame(height: h)
        .accessibilityElement()
        .accessibilityLabel(label ?? "Progress")
        .accessibilityValue(value.map { TTFormat.percent($0) } ?? "unavailable")
    }
}

/// DESIGN §2.16 multi-segment bars: `split` (power, h 8 r 4 gap 2), `composition` (memory, h 18 r 5 gap 2),
/// `volume` (h 10 r 5 gap 2, track `fillFree`). Segments are fractions of the whole, left to right; the bar is
/// clipped to its radius. `remainder` fills what's left (e.g. `fillRest`, `fillFree`); otherwise the track shows.
public struct TTSegmentBar: View, Equatable {
    public struct Segment: Equatable, Sendable {
        public var fraction: Double
        public var color: Color
        public var label: String?
        public init(_ fraction: Double, _ color: Color, label: String? = nil) {
            self.fraction = fraction
            self.color = color
            self.label = label
        }
    }

    public enum Style: Sendable, Equatable { case split, composition, volume }

    let segments: [Segment]
    let style: Style
    let remainder: Color?
    let label: String?

    public init(_ segments: [Segment], style: Style, remainder: Color? = nil, label: String? = nil) {
        self.segments = segments
        self.style = style
        self.remainder = remainder
        self.label = label
    }

    var height: CGFloat { style == .split ? 8 : (style == .composition ? 18 : 10) }
    var radius: CGFloat { style == .split ? TTRadius.r4 : TTRadius.r5 }

    /// Segment widths for `width` with `gap` between visible segments (a remainder counts as a segment).
    /// Fractions are of the whole bar (sum > 1 is normalized).
    nonisolated static func widths(_ fractions: [Double], remainder: Bool, width: CGFloat, gap: CGFloat) -> [CGFloat] {
        var f = fractions.map { $0.isFinite ? max(0, $0) : 0 }
        let used = f.reduce(0, +)
        if remainder { f.append(max(0, 1 - used)) }
        let visible = f.filter { $0 > 0 }.count
        let available = max(0, width - gap * CGFloat(max(0, visible - 1)))
        let total = max(f.reduce(0, +), 1)
        return f.map { $0 > 0 ? available * CGFloat($0 / total) : 0 }
    }

    public var body: some View {
        let fractions = segments.map(\.fraction)
        let colors = segments.map(\.color) + (remainder.map { [$0] } ?? [])
        let hasRemainder = remainder != nil
        let radius = radius
        let track = style == .volume ? TTColor.fillFree : Color.clear
        Canvas { ctx, size in
            let clip = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius, style: .continuous)
            ctx.clip(to: clip)
            ctx.fill(clip, with: .color(track))
            let widths = Self.widths(fractions, remainder: hasRemainder, width: size.width, gap: 2)
            var x: CGFloat = 0
            for (i, w) in widths.enumerated() where w > 0 {
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(colors[i]))
                x += w + 2
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label ?? "Composition")
        .accessibilityValue(segments.map { "\($0.label ?? "") \(TTFormat.percent($0.fraction))" }.joined(separator: ", "))
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
                    RoundedRectangle(cornerRadius: TTRadius.r3)
                        .fill(levels[i].color.opacity(on ? 1 : TTOpacity.inactiveThermalSegment))
                        .frame(height: 6)
                    Text(levels[i].title)
                        .font(on ? TTFont.body12Strong : TTFont.body12)
                        .foregroundStyle(on ? TTColor.textPrimary : TTColor.textSecondary)
                    Text(levels[i].detail).font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
