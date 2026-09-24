import AppKit
import MonitorModel
import MonitorScreens
import MonitorUIKit

/// Menu bar glyph images (DESIGN §4). Static states come from W3's `StatusGlyphRenderer` once it draws
/// (the W0b stub returns an empty image); pulse frames and the fallback are drawn here from `StatusGlyphSpec`,
/// because the locked `StatusGlyphRenderer.image(for:pointSize:)` has no pulse phase (w4-report ICR note).
@MainActor
enum StatusIconRenderer {
    private static var cache: [StatusGlyphSpec: NSImage] = [:]

    static func image(for state: AlertState, pulse: StatusPulse.Frame? = nil) -> NSImage {
        if pulse == nil {
            let kit = StatusGlyphRenderer.image(for: state, pointSize: 18)
            if !kit.representations.isEmpty { return kit }
        }
        return image(StatusGlyphSpec.make(state, pulse: pulse))
    }

    /// 18×18-pt image; the handler runs at draw time so `labelColor` follows the menu bar appearance.
    static func image(_ spec: StatusGlyphSpec, pointSize: CGFloat = 18) -> NSImage {
        if let hit = cache[spec] { return hit }
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(spec, in: ctx, box: rect.width)
            return true
        }
        img.isTemplate = spec.isTemplate
        img.accessibilityDescription = "Telltale"
        if cache.count > 64 { cache.removeAll() }
        cache[spec] = img
        return img
    }

    /// DESIGN §4.1/§4.2 geometry in a y-down box of `box` pt: viewBox (18) × box/18 × 8/9 around the center.
    static func draw(_ spec: StatusGlyphSpec, in ctx: CGContext, box: CGFloat) {
        let s = box / 18 * 8 / 9
        let c = CGPoint(x: box / 2, y: box / 2)
        let r = 6.4 * s, lw = 2.2 * s

        func color(_ ink: StatusGlyphSpec.Ink) -> CGColor {
            switch ink {
            case .label: spec.isTemplate ? NSColor.black.cgColor : NSColor.labelColor.cgColor
            case .elevated: NSColor(srgbRed: 1, green: 0xB3 / 255.0, blue: 0x40 / 255.0, alpha: 1).cgColor
            case .critical: NSColor(srgbRed: 1, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1).cgColor
            }
        }
        func arcsPath(_ ink: StatusGlyphSpec.Ink) -> CGPath? {
            let p = CGMutablePath()
            for (i, a) in spec.arcs.enumerated() where a == ink {
                let start = (7.0 + 72.0 * Double(i) - 90) * .pi / 180
                let end = (65.0 + 72.0 * Double(i) - 90) * .pi / 180
                p.move(to: CGPoint(x: c.x + r * cos(start), y: c.y + r * sin(start)))
                p.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
            }
            return p.isEmpty ? nil : p
        }
        func stroke(_ path: CGPath, _ ink: StatusGlyphSpec.Ink) {
            ctx.addPath(path)
            ctx.setStrokeColor(color(ink))
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }

        ctx.saveGState()
        ctx.setAlpha(spec.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let p = arcsPath(.label) { stroke(p, .label) }
        for ink in [StatusGlyphSpec.Ink.elevated, .critical] {
            guard let p = arcsPath(ink) else { continue }
            ctx.saveGState()
            ctx.setAlpha(ink == .critical ? spec.stressedAlpha : 1)    // only the critical arc pulses
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            stroke(p, ink)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        let dr = spec.dotRadius * s
        ctx.setFillColor(color(spec.dot))
        ctx.fillEllipse(in: CGRect(x: c.x - dr, y: c.y - dr, width: 2 * dr, height: 2 * dr))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
