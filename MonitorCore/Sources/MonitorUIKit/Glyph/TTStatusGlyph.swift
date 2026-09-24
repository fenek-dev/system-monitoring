import MonitorModel
import SwiftUI

/// DESIGN §4 status glyph geometry, in the 18×18 viewBox (y-down, θ clockwise from 12 o'clock).
/// 5 arcs of 58° (gaps 14°): arc i spans θ = 7° + 72°·i → 65° + 72°·i, r 6.4, stroke 2.2, round caps.
/// Arc order = `IconArc.allCases` (cpu, gpu, memory, network, thermals). Center dot r 1.4 / 1.6 / 2.1.
public enum StatusGlyphGeometry {
    public static let viewBox: CGFloat = 18
    public static let radius: CGFloat = 6.4
    public static let stroke: CGFloat = 2.2
    public static let arcOrder: [IconArc] = [.cpu, .gpu, .memory, .network, .thermals]

    public static func dotRadius(_ level: AlertLevel) -> CGFloat {
        switch level {
        case .calm: 1.4
        case .elevated: 1.6
        case .critical: 2.1
        }
    }

    /// Critical pulse at progress `p` 0…1 (§4.3): stressed-arc alpha 1 → 0.45 → 1, dot radius 2.1 → 2.9 → 2.1
    /// (viewBox units), peak at p = 0.5.
    public static func pulse(_ p: Double) -> (arcAlpha: Double, dotRadius: CGFloat) {
        let wave = sin(min(max(p, 0), 1) * .pi)
        return (1 - 0.55 * wave, dotRadius(.critical) + 0.8 * CGFloat(wave))
    }

    /// Point on the circle at θ (degrees clockwise from 12 o'clock), viewBox units.
    public static func point(theta: Double, radius r: CGFloat = radius) -> CGPoint {
        let t = theta * .pi / 180
        return CGPoint(x: 9 + r * CGFloat(sin(t)), y: 9 - r * CGFloat(cos(t)))
    }

    public static func arcSpan(_ i: Int) -> (start: Double, end: Double) {
        (7 + 72 * Double(i), 65 + 72 * Double(i))
    }

    /// Adds arc `i` (viewBox geometry scaled by `scale` about the canvas center `center`) to `path`.
    static func addArc(_ i: Int, to path: inout Path, center: CGPoint, scale: CGFloat) {
        let (s, e) = arcSpan(i)
        let r = radius * scale
        let start = CGPoint(x: center.x + r * CGFloat(sin(s * .pi / 180)), y: center.y - r * CGFloat(cos(s * .pi / 180)))
        path.move(to: start)
        // SwiftUI's `clockwise` is inverted in y-down space: false draws visually clockwise (§4.2).
        path.addArc(center: center, radius: r, startAngle: .degrees(s - 90), endAngle: .degrees(e - 90), clockwise: false)
    }

    /// Per-arc paint groups (§4.2): calm arcs in one path, then elevated, then critical.
    public static func groups(_ state: AlertState) -> (calm: [Int], elevated: [Int], critical: [Int]) {
        var calm: [Int] = [], elevated: [Int] = [], critical: [Int] = []
        for (i, arc) in arcOrder.enumerated() {
            switch state.paused ? .calm : (state.arcs[arc] ?? .calm) {
            case .calm: calm.append(i)
            case .elevated: elevated.append(i)
            case .critical: critical.append(i)
            }
        }
        return (calm, elevated, critical)
    }

    /// Highest arc/alert level (calm while paused).
    public static func level(_ state: AlertState) -> AlertLevel {
        guard !state.paused else { return .calm }
        return max(state.level, state.arcs.values.max() ?? .calm)
    }

    /// Draws the glyph (§4.2 paint order/compositing) into `ctx` with the viewBox scaled by `scale` about `center`.
    /// `pulse` 0…1 (critical pulse: stressed arcs 1 → 0.45 → 1, dot 2.1 → 2.9 → 2.1) — 0 = static.
    static func draw(_ state: AlertState, in ctx: inout GraphicsContext, center: CGPoint, scale: CGFloat,
                     calmColor: Color, template: Bool, pulse: Double = 0) {
        let g = groups(state)
        let level = self.level(state)
        let style = StrokeStyle(lineWidth: stroke * scale, lineCap: .round)
        let pulsed = self.pulse(pulse)
        ctx.drawLayer { layer in
            if state.paused { layer.opacity = 0.5 }
            var calm = Path()
            for i in (template ? Array(0..<5) : g.calm) { addArc(i, to: &calm, center: center, scale: scale) }
            layer.stroke(calm, with: .color(calmColor), style: style)
            if !template {
                for (arcs, color) in [(g.elevated, TTColor.statusElevated), (g.critical, TTColor.statusCritical)] where !arcs.isEmpty {
                    var p = Path()
                    for i in arcs { addArc(i, to: &p, center: center, scale: scale) }
                    let dim = color == TTColor.statusCritical ? pulsed.arcAlpha : 1
                    layer.drawLayer { sub in
                        sub.opacity = dim
                        sub.stroke(p, with: .color(color), style: style)
                    }
                }
            }
            var r = !template && level == .critical ? pulsed.dotRadius : dotRadius(template ? .calm : level)
            r *= scale
            let dotColor = template || level == .calm ? calmColor : TTColor.level(level)
            layer.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), with: .color(dotColor))
        }
    }
}

/// DESIGN §2.24 / §4 status glyph as a SwiftUI view: the 18-unit viewBox scaled to `size` (no 8/9 factor; popover
/// header uses 20 → r 7.11, stroke 2.44). `template: false` (popover header): calm arcs `textPrimary`, stressed arcs
/// and the dot in the status colors. `template: true`: monochrome in the foreground color. Paused: 0.5 alpha, calm.
public struct TTStatusGlyph: View, Equatable {
    let state: AlertState
    let size: CGFloat
    let template: Bool
    let pulse: Double

    public init(state: AlertState, size: CGFloat = 16, template: Bool) {
        self.init(state: state, size: size, template: template, pulse: 0)
    }

    /// `pulse` 0…1 drives the one-shot critical pulse (600 ms ease-in-out; skipped with Reduce Motion).
    public init(state: AlertState, size: CGFloat = 16, template: Bool, pulse: Double) {
        self.state = state
        self.size = size
        self.template = template
        self.pulse = pulse
    }

    public var body: some View {
        let state = state, size = size, template = template, pulse = pulse
        Canvas { ctx, canvas in
            StatusGlyphGeometry.draw(state, in: &ctx, center: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
                                     scale: size / StatusGlyphGeometry.viewBox,
                                     calmColor: template ? .primary : TTColor.textPrimary, template: template, pulse: pulse)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
