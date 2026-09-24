import AppKit
import MonitorModel
import MonitorSnapshotTesting
import SwiftUI
import Testing
@testable import MonitorUIKit

@MainActor @Suite struct StatusGlyphTests {
    func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

    @Test func arcEndpointsMatchTheSpecTable() {
        // DESIGN §4.1 table (viewBox units).
        let expected: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 9.78, y: 2.65), CGPoint(x: 14.80, y: 6.30)),
            (CGPoint(x: 15.28, y: 7.78), CGPoint(x: 13.36, y: 13.68)),
            (CGPoint(x: 12.10, y: 14.60), CGPoint(x: 5.90, y: 14.60)),
            (CGPoint(x: 4.64, y: 13.68), CGPoint(x: 2.72, y: 7.78)),
            (CGPoint(x: 3.20, y: 6.30), CGPoint(x: 8.22, y: 2.65)),
        ]
        for (i, (s, e)) in expected.enumerated() {
            let span = StatusGlyphGeometry.arcSpan(i)
            #expect(near(StatusGlyphGeometry.point(theta: span.start), s), "arc \(i) start")
            #expect(near(StatusGlyphGeometry.point(theta: span.end), e), "arc \(i) end")
        }
    }

    @Test func menuBarCanvasScale() {
        // 18-pt canvas, s = 8/9: r 5.689, stroke 1.956; arc 0 start (9.693, 3.353).
        let s: CGFloat = 8.0 / 9.0
        #expect(abs(StatusGlyphGeometry.radius * s - 5.689) < 0.001)
        #expect(abs(StatusGlyphGeometry.stroke * s - 1.956) < 0.001)
        var p = Path()
        StatusGlyphGeometry.addArc(0, to: &p, center: CGPoint(x: 9, y: 9), scale: s)
        var first: CGPoint?
        p.forEach { if case .move(let pt) = $0, first == nil { first = pt } }
        #expect(near(first!, CGPoint(x: 9.693, y: 3.353)))
        // The arc is traced clockwise: its bounds stay in the upper-right quadrant.
        #expect(p.boundingRect.minX >= 9.6 && p.boundingRect.maxY <= 9)
        #expect(abs(StatusGlyphGeometry.dotRadius(.calm) * s - 1.244) < 0.001)
        #expect(abs(StatusGlyphGeometry.dotRadius(.elevated) * s - 1.422) < 0.001)
        #expect(abs(StatusGlyphGeometry.dotRadius(.critical) * s - 1.867) < 0.001)
    }

    @Test func paintGroupsFollowArcLevels() {
        var arcs = Dictionary(uniqueKeysWithValues: IconArc.allCases.map { ($0, AlertLevel.calm) })
        arcs[.thermals] = .elevated
        arcs[.memory] = .critical
        let state = AlertState(level: .critical, arcs: arcs)
        let g = StatusGlyphGeometry.groups(state)
        #expect(g.calm == [0, 1, 3] && g.elevated == [4] && g.critical == [2])
        #expect(StatusGlyphGeometry.level(state) == .critical)
        var paused = state
        paused.paused = true
        #expect(StatusGlyphGeometry.groups(paused).calm == [0, 1, 2, 3, 4])
        #expect(StatusGlyphGeometry.level(paused) == .calm)
    }

    @Test func rendererTemplateAndCache() {
        let calm = StatusGlyphRenderer.image(for: .calm)
        #expect(calm.isTemplate)
        #expect(calm.size == NSSize(width: 18, height: 18))
        #expect(StatusGlyphRenderer.image(for: .calm) === calm)
        let hot = StatusGlyphRenderer.image(for: AlertState(level: .elevated, arcs: GalleryGlyph.arcs(.thermals, .elevated)))
        #expect(!hot.isTemplate)
        var paused = AlertState.calm
        paused.paused = true
        let dim = StatusGlyphRenderer.image(for: paused)
        #expect(dim.isTemplate && dim !== calm)
        #expect(StatusGlyphRenderer.pulseFrames(for: AlertState(level: .critical, arcs: GalleryGlyph.arcs(.thermals, .critical))).count == 18)
    }

    @Test func pulseMidFrameIsThePeak() {
        let values = StatusGlyphRenderer.pulseValues
        #expect(values.count == 18)
        #expect(values[0] == 0)
        let peak = StatusGlyphGeometry.pulse(values[9])
        #expect(abs(peak.arcAlpha - 0.45) < 1e-9)
        #expect(abs(peak.dotRadius - 2.9) < 1e-9)
        let rest = StatusGlyphGeometry.pulse(0)
        #expect(rest.arcAlpha == 1 && abs(rest.dotRadius - 2.1) < 1e-9)
        // Monotone up to the peak, then down.
        #expect(zip(values[0...9], values[1...9]).allSatisfy { $0 < $1 })
    }

    /// Rasterize the 18-pt image at 2x and check the thermals arc is amber, the others label-colored.
    @Test func rendererColorsTheStressedArc() throws {
        let state = AlertState(level: .elevated, arcs: GalleryGlyph.arcs(.thermals, .elevated))
        let image = StatusGlyphRenderer.image(for: state)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        }
        NSGraphicsContext.restoreGraphicsState()
        // Arc 4 midpoint θ = 324°, arc 1 midpoint θ = 108°, in the 18-pt canvas (×8/9 about 9,9), y-down → rep rows.
        func color(theta: Double) -> NSColor? {
            let r = 6.4 * 8.0 / 9.0
            let x = 9 + r * sin(theta * .pi / 180), y = 9 - r * cos(theta * .pi / 180)
            return rep.colorAt(x: Int(x * 2), y: Int(y * 2))
        }
        let amber = try #require(color(theta: 324)?.usingColorSpace(.sRGB))
        #expect(amber.redComponent > 0.9 && amber.greenComponent > 0.6 && amber.greenComponent < 0.8 && amber.blueComponent < 0.4)
        let calm = try #require(color(theta: 108)?.usingColorSpace(.sRGB))
        #expect(calm.redComponent > 0.8 && calm.greenComponent > 0.8 && calm.blueComponent > 0.8) // label (white) on dark
    }
}
