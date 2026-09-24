import MonitorModel
import MonitorUIKit
import SwiftUI

/// `Equatable` host of W3's `TTPopoverRow` (DESIGN §2.22): compares the row data only, so a tick that leaves a
/// row's data unchanged does not rebuild it. Expansion lines come from `topApps` (TTPopoverRow ranks them);
/// double-click / app-line clicks go through `appCommands` inside TTPopoverRow.
struct PopoverRowView: View, Equatable {
    let row: PopoverModel.Row
    let expanded: Bool
    let topApps: [AppSample]
    let toggle: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.expanded == b.expanded && a.topApps == b.topApps
    }

    var body: some View {
        TTPopoverRow(category: row.category, subtitle: row.subtitle, value: row.value,
                     unavailableReason: row.unavailableReason, points: row.points, yDomain: row.domain,
                     compact: row.compact,
                     expanded: Binding(get: { expanded }, set: { if $0 != expanded { toggle() } }),
                     topApps: topApps, level: row.stress)
    }
}

/// `Equatable` host of W3's `TTAlertBanner` (DESIGN §2.23).
struct PopoverBannerView: View, Equatable {
    let banner: PopoverModel.Banner
    let perform: (PopoverModel.Banner.Action) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.banner == b.banner }

    var body: some View {
        TTAlertBanner(title: "Alert", message: banner.message, level: banner.level,
                      actions: banner.buttons.map { b in
                          BannerAction(id: b.title, title: b.title) { perform(b.action) }
                      })
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
