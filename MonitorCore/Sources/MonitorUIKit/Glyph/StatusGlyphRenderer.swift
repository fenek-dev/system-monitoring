import AppKit
import MonitorModel
import SwiftUI

/// DESIGN §4 menu-bar glyph images (`NSStatusItem.squareLength`, 18×18 pt canvas, viewBox scaled 8/9 about (9, 9):
/// arc r 5.689, stroke 1.956, dot r 1.244 / 1.422 / 1.867).
/// - Calm (not paused): one black path for all arcs + dot, `isTemplate = true` (follows the menu bar tint).
/// - Elevated/critical: non-stressed arcs in `NSColor.labelColor` resolved **at draw time** (drawing handler, no
///   cached bitmap), stressed arcs amber/red (elevated before critical), dot in the highest level's color;
///   `isTemplate = false`.
/// - Paused: the calm template inside a transparency layer at 0.5 alpha.
/// Images are cached per (arc levels, level, paused, pointSize); `pulseFrames` gives the 18-frame critical pulse.
@MainActor public enum StatusGlyphRenderer {
    private static var cache: [String: NSImage] = [:]

    static func key(_ state: AlertState, _ pointSize: CGFloat, pulse: Double = 0) -> String {
        let arcs = StatusGlyphGeometry.arcOrder.map { String((state.paused ? .calm : state.arcs[$0] ?? .calm).rawValue) }.joined()
        return "\(arcs)|\(StatusGlyphGeometry.level(state).rawValue)|\(state.paused)|\(pointSize)|\(pulse)"
    }

    public static func image(for state: AlertState, pointSize: CGFloat = 18) -> NSImage {
        image(for: state, pointSize: pointSize, pulse: 0)
    }

    static func image(for state: AlertState, pointSize: CGFloat, pulse: Double) -> NSImage {
        let k = key(state, pointSize, pulse: pulse)
        if let hit = cache[k] { return hit }
        let level = StatusGlyphGeometry.level(state)
        let template = level == .calm
        let groups = StatusGlyphGeometry.groups(state)
        let paused = state.paused
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: cg, rect: rect, groups: groups, level: level, template: template, paused: paused, pulse: pulse)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Telltale"
        cache[k] = image
        return image
    }

    /// 18 frames at 30 fps (600 ms, ease-in-out) for one critical pulse; the caller then restores `image(for:)`.
    public static func pulseFrames(for state: AlertState, pointSize: CGFloat = 18) -> [NSImage] {
        (0..<18).map { f in
            let t = Double(f) / 17
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            return image(for: state, pointSize: pointSize, pulse: eased)
        }
    }

    /// y-down drawing (flipped image) with the §4.2 paint order and transparency layers.
    nonisolated static func draw(in cg: CGContext, rect: CGRect, groups: (calm: [Int], elevated: [Int], critical: [Int]),
                                 level: AlertLevel, template: Bool, paused: Bool, pulse: Double) {
        let s = rect.width / StatusGlyphGeometry.viewBox * 8 / 9
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let wave = sin(pulse * .pi)
        let label: CGColor = template ? NSColor.black.cgColor : NSColor.labelColor.cgColor
        func path(_ arcs: [Int]) -> CGPath {
            var p = Path()
            for i in arcs { StatusGlyphGeometry.addArc(i, to: &p, center: center, scale: s) }
            return p.cgPath
        }
        cg.saveGState()
        cg.setAlpha(paused ? 0.5 : 1)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setLineWidth(StatusGlyphGeometry.stroke * s)
        cg.setLineCap(.round)
        cg.addPath(path(template ? Array(0..<5) : groups.calm))
        cg.setStrokeColor(label)
        cg.strokePath()
        if !template {
            for (arcs, hex) in [(groups.elevated, TTHex.statusElevated), (groups.critical, TTHex.statusCritical)] where !arcs.isEmpty {
                cg.saveGState()
                cg.setAlpha(hex == TTHex.statusCritical ? 1 - 0.55 * wave : 1)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
                cg.addPath(path(arcs))
                cg.setStrokeColor(NSColor(hex: hex).cgColor)
                cg.strokePath()
                cg.endTransparencyLayer()
                cg.restoreGState()
            }
        }
        var r = StatusGlyphGeometry.dotRadius(template ? .calm : level)
        if !template && level == .critical { r += 0.8 * CGFloat(wave) }
        r *= s
        let dot: CGColor = switch template ? .calm : level {
        case .calm: label
        case .elevated: NSColor(hex: TTHex.statusElevated).cgColor
        case .critical: NSColor(hex: TTHex.statusCritical).cgColor
        }
        cg.setFillColor(dot)
        cg.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        cg.endTransparencyLayer()
        cg.restoreGState()
    }
}
