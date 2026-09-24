import SwiftUI

/// DESIGN §1 tokens the shell chrome needs. `MonitorUIKit` locks only `TTColor.category/level` and a few
/// `TTFont` names (ARCHITECTURE §5.12), so the chrome keeps its own copies of the exact DESIGN values here.
/// Swap for the `TTColor`/`TTFont` tokens once W3 publishes them (w4-report follow-up).
enum ShellStyle {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: a)
    }

    // Backgrounds
    static let bgWindow = hex(0x1B1B1D)
    static let bgHeader = hex(0x202023)
    static let bgCard = hex(0x232326)
    static let bgSidebar = hex(0x242427)
    static let bgPopover = hex(0x28282C, 0.97)

    // Text
    static let textPrimary = hex(0xF2F2F4)
    static let textSecondary = hex(0xA8A8B0)
    static let textTertiary = hex(0x9A9AA2)

    // Lines and fills
    static let borderCard = Color.white.opacity(0.07)
    static let borderPopover = Color.white.opacity(0.14)
    static let separator = Color.white.opacity(0.08)
    static let edgeSidebar = Color.black.opacity(0.50)
    static let edgeHeader = Color.black.opacity(0.45)
    static let fillHover = Color.white.opacity(0.05)
    static let fillIconButton = Color.white.opacity(0.08)
    static let accent = hex(0x0A84FF)

    // Typography (DESIGN §1.2)
    static let pageTitle = Font.system(size: 15, weight: .semibold)
    static let body13 = Font.system(size: 13)
    static let body12Strong = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .semibold)

    // Geometry
    static let sidebarWidth: CGFloat = 220
    static let headerHeight: CGFloat = 52
    static let dashboardSize = CGSize(width: 1280, height: 860)
    static let dashboardMinSize = CGSize(width: 1100, height: 720)
    static let popoverWidth: CGFloat = 360
    static let settingsWidth: CGFloat = 520
}

/// DESIGN §1.4 16-grid stroke icons the shell draws (pause, play, settings, drag handle).
struct ShellIcon: Shape {
    enum Kind { case pause, play, settings, dragHandle }
    var kind: Kind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let o = CGPoint(x: rect.midX - 8 * s, y: rect.midY - 8 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            path.move(to: p(x0, y0))
            path.addLine(to: p(x1, y1))
        }
        switch kind {
        case .pause:
            line(6, 3.5, 6, 12.5)
            line(10, 3.5, 10, 12.5)
        case .play:
            path.move(to: p(5, 3.5))
            path.addLine(to: p(5, 12.5))
            path.addLine(to: p(12, 8))
            path.closeSubpath()
        case .settings:
            line(2, 4.5, 9, 4.5)
            line(12, 4.5, 14, 4.5)
            line(2, 11.5, 4, 11.5)
            line(7, 11.5, 14, 11.5)
            path.addEllipse(in: CGRect(x: p(9, 3).x, y: p(9, 3).y, width: 3 * s, height: 3 * s))
            path.addEllipse(in: CGRect(x: p(4, 10).x, y: p(4, 10).y, width: 3 * s, height: 3 * s))
        case .dragHandle:
            line(4, 5.5, 12, 5.5)
            line(4, 8, 12, 8)
            line(4, 10.5, 12, 10.5)
        }
        return path
    }
}

extension ShellIcon {
    /// Stroked at 1.5 pt (scaled), round caps/joins.
    func icon(size: CGFloat = 16, color: Color = ShellStyle.textSecondary) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// DESIGN §2.14 `iconButton` (28 header / 26 popover): transparent, hover `fillIconButton`, `.help` + a11y label.
struct ShellIconButton: View {
    var icon: ShellIcon.Kind
    var help: String
    var size: CGFloat = 28
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ShellIcon(kind: icon).icon()
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? ShellStyle.fillIconButton : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
