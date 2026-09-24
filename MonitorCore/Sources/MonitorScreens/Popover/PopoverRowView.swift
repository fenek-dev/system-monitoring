import MonitorModel
import MonitorUIKit
import SwiftUI

// TODO(W3 T11): replace with `TTPopoverRow` once W3 lands it (the W0b stub draws nothing).
/// DESIGN §2.22 popover category row.
/// - Full: height 44, padding 0×10, radius 7, HStack gap 10: icon 16; VStack title `body13` + sub `caption`
///   `textSecondary`; sparkline 84×22 (line 1.25, fill 0.22); value 74 wide right-aligned `body13Value`.
/// - Compact: height 36, `body12`: icon 16, title (flex), detail `textSecondary`, value 74 semibold.
/// - Expansion (ADDED): under the row in the same rounded fill (white @ 0.06), padding 0 10 8 36, 3 lines × 24
///   (tile 16, name `body12`, value in the 74 column `textSecondary`); "No app activity" when empty.
/// - Stressed: `statusElevatedRowFill` (or critical) with the value in the status color. Hover `fillHover`.
struct PopoverRowView: View, Equatable {
    let row: PopoverModel.Row
    let expanded: Bool
    let lines: [PopoverModel.AppLine]
    let toggle: () -> Void
    let openPage: () -> Void
    let openApp: (AppKey) -> Void
    @State private var hovering = false

    /// Data only; the closures are rebuilt every time and never change behaviour for equal data.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.expanded == b.expanded && a.lines == b.lines
    }

    private var fill: Color {
        if let f = TTColor.rowFill(row.stress) { return f }
        if expanded { return TTColor.fillExpanded }
        return hovering ? TTColor.fillHover : .clear
    }

    private var valueColor: Color { row.stress == .calm ? TTColor.textPrimary : TTColor.level(row.stress) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group { if row.compact { compactLine } else { fullLine } }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
                // Single click toggles at once; a double click (toggle twice = unchanged) also opens the page.
                .onTapGesture(perform: toggle)
                .simultaneousGesture(TapGesture(count: 2).onEnded(openPage))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(expanded ? "Collapse top apps" : "Show top apps")
            if expanded { expansion.transition(.opacity) }
        }
        .background(RoundedRectangle(cornerRadius: TTRadius.r7, style: .continuous).fill(fill))
        .onHover { hovering = $0 }
    }

    private var icon: some View { TTIcon(TTIconName.category(row.category), size: 16) }

    private var fullLine: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(row.category.ttTitle).font(TTFont.body13).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                    .cssLine(13)
                subtitle(TTFont.caption).cssLine(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TTAreaChart(row.points, color: TTColor.category(row.category), yDomain: row.domain,
                        fillOpacity: TTChartFill.sparkline, lineWidth: TTStroke.sparkThin,
                        showsCollecting: row.unavailableReason == nil)   // unavailable: empty frame, not "Collecting…"
                .frame(width: 84, height: 22)
            value(TTFont.body13Value)
        }
        .frame(height: 44)
    }

    private var compactLine: some View {
        HStack(spacing: 10) {
            icon
            Text(row.category.ttTitle).font(TTFont.body12).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            subtitle(TTFont.body12)
                .layoutPriority(1)
            value(TTFont.body12Strong)
        }
        .frame(height: 36)
    }

    @ViewBuilder private func subtitle(_ font: Font) -> some View {
        if let s = row.subtitle {
            Text(s).font(font).foregroundStyle(TTColor.textSecondary).monospacedDigit()
                .lineLimit(1).truncationMode(.tail)
        } else {
            MetricValue(nil, unavailableReason: row.unavailableReason, font: font)
        }
    }

    private func value(_ font: Font) -> some View {
        MetricValue(row.value, unavailableReason: row.unavailableReason, font: font)
            .foregroundStyle(valueColor)
            .minimumScaleFactor(0.85)
            .frame(width: 74, alignment: .trailing)
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.category == .thermals && !lines.isEmpty {
                Text("by power").font(TTFont.caption).foregroundStyle(TTColor.textTertiary).frame(height: 16)
            }
            if lines.isEmpty {
                Text("No app activity").font(TTFont.caption).foregroundStyle(TTColor.textTertiary).frame(height: 24)
            }
            ForEach(lines) { line in
                HStack(spacing: 8) {
                    TTAppTile(identity: line.identity, name: line.name, size: 16)
                    Text(line.name).font(TTFont.body12).foregroundStyle(TTColor.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.value).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .frame(width: 74, alignment: .trailing)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture { openApp(line.key) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 36, bottom: 8, trailing: 10))
    }
}

// TODO(W3 T11): replace with `TTAlertBanner` once W3 lands it (the W0b stub draws nothing).
/// DESIGN §2.23 alert banner: margin 2 top / 6 horizontal / 6 bottom; padding 10×12, radius 8, level fill with
/// 1-pt level border; VStack gap 8 of `bannerText` (`textPrimary`) and an HStack gap 6 of small secondary buttons.
struct PopoverBannerView: View, Equatable {
    let banner: PopoverModel.Banner
    let perform: (PopoverModel.Banner.Action) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.banner == b.banner }

    /// The artboard's line box is 17.5 pt (`bannerText` 12 pt); SwiftUI's natural 12-pt line is ≈ 14.3 pt, so the
    /// gap goes between lines (`lineSpacing`) and half of it above the first / below the last line (CSS half-leading).
    static let lineBox: CGFloat = 17.5
    static let naturalLine: CGFloat = 14.3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TTRadius.r8, style: .continuous)
        let leading = Self.lineBox - Self.naturalLine
        VStack(alignment: .leading, spacing: 8) {
            Text(banner.message)
                .font(TTFont.bannerText).lineSpacing(leading)
                .foregroundStyle(TTColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, leading / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(banner.buttons, id: \.title) { b in
                    Button(b.title) { perform(b.action) }.buttonStyle(TTButtonStyle(.smallSecondary))
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(shape.fill(TTColor.bannerFill(banner.level)))
        .overlay(shape.strokeBorder(TTColor.bannerBorder(banner.level), lineWidth: 1))
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 6, trailing: 6))
    }
}

// TODO(W3): replace with `TTStatusGlyph(state:size:20,template:false)` once W3 lands it (stub draws nothing).
/// DESIGN §2.24 / §4.3 popover header glyph: the 18-unit viewBox scaled 20/18 into 20×20 (no 8/9 factor):
/// arcs r 7.111, stroke 2.444, dot r ×20/18; calm ink `textPrimary`; arcs grouped by ink, stressed on top.
struct PopoverGlyph: View {
    let state: AlertState

    var body: some View {
        let spec = StatusGlyphSpec.make(state)
        Canvas { ctx, size in
            let s = size.width / 18
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.opacity = spec.alpha
            for ink in [StatusGlyphSpec.Ink.label, .elevated, .critical] {
                var p = Path()
                for (i, arcInk) in spec.arcs.enumerated() where arcInk == ink {
                    let start = 7.0 + 72.0 * Double(i), end = 65.0 + 72.0 * Double(i)
                    let rad = start * .pi / 180, R = 6.4 * s
                    p.move(to: CGPoint(x: c.x + R * sin(rad), y: c.y - R * cos(rad)))  // separate subpaths
                    p.addArc(center: c, radius: R, startAngle: .degrees(start - 90),
                             endAngle: .degrees(end - 90), clockwise: false)
                }
                ctx.stroke(p, with: .color(Self.color(ink)), style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
            }
            let r = spec.dotRadius * s
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Self.color(spec.dot)))
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    static func color(_ ink: StatusGlyphSpec.Ink) -> Color {
        switch ink {
        case .label: TTColor.textPrimary
        case .elevated: TTColor.statusElevated
        case .critical: TTColor.statusCritical
        }
    }
}
