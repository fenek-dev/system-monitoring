import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell status glyph spec")
struct ShellStatusGlyphTests {
    @Test func calmIsTemplate() {
        let s = StatusGlyphSpec.make(.calm)
        #expect(s.isTemplate && s.alpha == 1 && s.dotRadius == 1.4)
        #expect(s.arcs == Array(repeating: .label, count: 5))
    }

    @Test func elevatedThermalsTintsArc4AndDot() {
        let s = StatusGlyphSpec.make(.preview(.elevated))
        #expect(!s.isTemplate)
        #expect(s.arcs == [.label, .label, .label, .label, .elevated])
        #expect(s.dot == .elevated && s.dotRadius == 1.6)
    }

    @Test func mixedAlertsDotTakesHighest() {
        var st = AlertState.preview(.elevated, arc: .memory)
        st.arcs[.cpu] = .critical
        st.level = .critical
        let s = StatusGlyphSpec.make(st)
        #expect(s.arcs == [.critical, .label, .elevated, .label, .label])
        #expect(s.dot == .critical && s.dotRadius == 2.1)
    }

    @Test func pausedIsDimmedTemplateAndSuppressesAlerts() {
        var st = AlertState.preview(.critical)
        st.paused = true
        let s = StatusGlyphSpec.make(st)
        #expect(s.isTemplate && s.alpha == 0.5 && s.arcs.allSatisfy { $0 == .label })
    }

    @Test func pulseCurve() {
        let f = StatusPulse.frames
        #expect(f.count == 18)
        #expect(f.first == StatusPulse.Frame(dotRadius: 2.1, arcAlpha: 1))
        #expect(abs(f.last!.dotRadius - 2.1) < 1e-9)
        let peak = f.max { $0.dotRadius < $1.dotRadius }!
        #expect(peak.dotRadius > 2.85 && peak.dotRadius <= 2.9)
        #expect(peak.arcAlpha < 0.5 && peak.arcAlpha >= 0.45)
        let s = StatusGlyphSpec.make(.preview(.critical), pulse: peak)
        #expect(s.dotRadius == peak.dotRadius && s.stressedAlpha == peak.arcAlpha)
        // no pulse look on non-critical states
        #expect(StatusGlyphSpec.make(.preview(.elevated), pulse: peak).dotRadius == 1.6)
    }

    @Test func pulseOncePerTokenChange() {
        let crit = AlertState.preview(.critical, pulseToken: 3)
        #expect(StatusPulse.shouldPulse(previousToken: 2, state: crit, reduceMotion: false))
        #expect(!StatusPulse.shouldPulse(previousToken: 3, state: crit, reduceMotion: false))
        #expect(!StatusPulse.shouldPulse(previousToken: nil, state: crit, reduceMotion: false))   // launch
        #expect(!StatusPulse.shouldPulse(previousToken: 2, state: crit, reduceMotion: true))
        #expect(!StatusPulse.shouldPulse(previousToken: 2, state: .preview(.elevated, pulseToken: 3),
                                         reduceMotion: false))
    }

    @Test func statusLines() {
        #expect(StatusLine.text(for: .calm) == "All systems nominal")
        var st = AlertState.preview(.elevated)
        st.active = [ActiveAlert(kind: .thermalPressure(.fair), level: .elevated),
                     ActiveAlert(kind: .memoryPressure(.warning), level: .elevated, arc: .memory)]
        #expect(StatusLine.text(for: st) == "Thermal pressure: Fair · +1")
        st.active = [ActiveAlert(kind: .runawayApp(AppKey(kind: .app, id: "com.x"), cpuPercent: 120),
                                 level: .elevated, arc: .cpu,
                                 culprit: AppIdentity(key: AppKey(kind: .app, id: "com.x"), displayName: "Xcode"))]
        #expect(StatusLine.text(for: st) == "Runaway app: Xcode")
        st.paused = true
        #expect(StatusLine.text(for: st) == "Sampling paused")
    }
}
