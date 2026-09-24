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

    private func runaway(_ cpu: Double, token: Int = 0) -> AlertState {
        let key = AppKey(kind: .app, id: "com.x")
        var st = AlertState.preview(.elevated, arc: .cpu, pulseToken: token)
        st.active = [ActiveAlert(kind: .runawayApp(key, cpuPercent: cpu), level: .elevated, arc: .cpu,
                                 culprit: AppIdentity(key: key, displayName: "Xcode"))]
        return st
    }

    @Test func presenterIgnoresPerTickAlertNoise() {
        var p = StatusItemPresenter()
        let first = p.apply(runaway(120), reduceMotion: false)
        #expect(first.glyph == StatusGlyphSpec.make(runaway(120)))
        #expect(first.statusLine == "Runaway app: Xcode")
        #expect(!first.cancelPulse && !first.startPulse)
        // cpuPercent moves every tick: nothing to do
        #expect(p.apply(runaway(131), reduceMotion: false).isEmpty)
        #expect(p.apply(runaway(97), reduceMotion: false).isEmpty)
    }

    @Test func presenterPulsesOncePerTokenAndCancelsOnlyOnSpecOrLevelChange() {
        var p = StatusItemPresenter()
        _ = p.apply(.calm, reduceMotion: false)
        var crit = AlertState.preview(.critical, pulseToken: 1)
        let enter = p.apply(crit, reduceMotion: false)
        #expect(enter.startPulse && enter.glyph != nil && enter.statusLine == nil)
        // same critical state again (e.g. next tick, active list detail changed): pulse keeps running
        crit.active = [ActiveAlert(kind: .thermalPressure(.critical), level: .critical)]
        let tick = p.apply(crit, reduceMotion: false)
        #expect(!tick.cancelPulse && !tick.startPulse && tick.glyph == nil)
        #expect(tick.statusLine == "Thermal pressure: Critical")
        // stress clears → cancel pulse, redraw
        let clear = p.apply(.calm, reduceMotion: false)
        #expect(clear.cancelPulse && clear.glyph == StatusGlyphSpec.make(.calm) && !clear.startPulse)
        // re-entering critical with a new token pulses again
        #expect(p.apply(.preview(.critical, pulseToken: 2), reduceMotion: false).startPulse)
        // reduce motion: no pulse
        _ = p.apply(.calm, reduceMotion: true)
        #expect(!p.apply(.preview(.critical, pulseToken: 3), reduceMotion: true).startPulse)
    }
}
