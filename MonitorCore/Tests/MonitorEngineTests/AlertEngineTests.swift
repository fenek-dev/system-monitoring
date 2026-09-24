import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000 + s) }

private func app(_ id: String, cpu: Double?, kind: AppKey.Kind = .app, mem: UInt64? = nil, watts: Double? = nil) -> AppSample {
    AppSample(identity: AppIdentity(key: AppKey(kind: kind, id: id), displayName: id), cpuPercent: cpu, memory: mem,
              energyWatts: watts)
}

@Suite struct AlertEngineTests {
    @Test(arguments: [(ThermalPressure.nominal, AlertLevel.calm), (.fair, .elevated), (.serious, .critical), (.critical, .critical)])
    func thermalTable(_ p: ThermalPressure, _ level: AlertLevel) {
        var e = AlertEngine()
        let s = e.update(thermal: p, memory: nil, apps: [], at: at(0)).state
        #expect(s.level == level)
        #expect(s.arcs[.thermals] == level)
        #expect(s.arcs[.memory] == .calm && s.arcs[.cpu] == .calm)
        #expect(s.active.count == (level == .calm ? 0 : 1))
        if level != .calm { #expect(s.active.first?.id == "thermal" && s.active.first?.arc == .thermals) }
    }

    @Test(arguments: [(MemoryPressureLevel.normal, AlertLevel.calm), (.warning, .elevated), (.critical, .critical)])
    func memoryTable(_ m: MemoryPressureLevel, _ level: AlertLevel) {
        var e = AlertEngine()
        let s = e.update(thermal: nil, memory: m, apps: [], at: at(0)).state
        #expect(s.level == level)
        #expect(s.arcs[.memory] == level)
    }

    @Test func nilInputsNeverRaise() {
        var e = AlertEngine()
        let s = e.update(thermal: nil, memory: nil, apps: [app("a", cpu: nil)], at: at(0)).state
        #expect(s == .calm)
    }

    @Test func stepUpImmediateStepDownAfterContinuousHold() {
        var e = AlertEngine()
        #expect(e.update(thermal: .serious, memory: nil, apps: [], at: at(0)).state.level == .critical)
        #expect(e.update(thermal: .fair, memory: nil, apps: [], at: at(1)).state.level == .critical)
        #expect(e.update(thermal: .fair, memory: nil, apps: [], at: at(10.9)).state.level == .critical)
        #expect(e.update(thermal: .fair, memory: nil, apps: [], at: at(11)).state.level == .elevated)   // 10 s held
        // an interruption restarts the hold
        #expect(e.update(thermal: .nominal, memory: nil, apps: [], at: at(12)).state.level == .elevated)
        #expect(e.update(thermal: .fair, memory: nil, apps: [], at: at(15)).state.level == .elevated)
        #expect(e.update(thermal: .nominal, memory: nil, apps: [], at: at(16)).state.level == .elevated)
        #expect(e.update(thermal: .nominal, memory: nil, apps: [], at: at(25)).state.level == .elevated)
        #expect(e.update(thermal: .nominal, memory: nil, apps: [], at: at(26)).state.level == .calm)
        #expect(e.state.active.isEmpty)
    }

    @Test func stepDownTakesHighestLevelSeenDuringHold() {
        var e = AlertEngine()
        _ = e.update(thermal: .critical, memory: nil, apps: [], at: at(0))
        _ = e.update(thermal: .fair, memory: nil, apps: [], at: at(1))
        _ = e.update(thermal: .nominal, memory: nil, apps: [], at: at(5))
        #expect(e.update(thermal: .nominal, memory: nil, apps: [], at: at(11)).state.level == .elevated)
    }

    @Test func nilAfterAlertStepsDownAfterHold() {
        var e = AlertEngine()
        _ = e.update(thermal: nil, memory: .critical, apps: [], at: at(0))
        #expect(e.update(thermal: nil, memory: nil, apps: [], at: at(5)).state.level == .critical)
        #expect(e.update(thermal: nil, memory: nil, apps: [], at: at(14.9)).state.level == .critical)
        #expect(e.update(thermal: nil, memory: nil, apps: [], at: at(15)).state.level == .calm)
    }

    @Test func overallIsMaxAndActiveSorted() {
        var e = AlertEngine()
        _ = e.update(thermal: .fair, memory: nil, apps: [], at: at(0))
        let s = e.update(thermal: .fair, memory: .critical, apps: [], at: at(1)).state
        #expect(s.level == .critical)
        #expect(s.active.map(\.id) == ["memory", "thermal"])          // level desc, then since asc
        #expect(s.active.last?.since == at(0))
    }

    @Test func pulseTokenCountsEntriesIntoCritical() {
        var e = AlertEngine()
        #expect(e.update(thermal: .serious, memory: nil, apps: [], at: at(0)).state.pulseToken == 1)
        #expect(e.update(thermal: .critical, memory: .critical, apps: [], at: at(1)).state.pulseToken == 1)   // still critical
        _ = e.update(thermal: .nominal, memory: nil, apps: [], at: at(2))
        #expect(e.update(thermal: .nominal, memory: nil, apps: [], at: at(12)).state.pulseToken == 1)
        #expect(e.state.level == .calm)
        #expect(e.update(thermal: .serious, memory: nil, apps: [], at: at(13)).state.pulseToken == 2)
    }

    @Test func culpritsForThermalAndMemory() throws {
        var e = AlertEngine()
        let apps = [app("sys", cpu: 500, kind: .system, mem: 9 << 30, watts: 9), app("hot", cpu: 90, mem: 1 << 30, watts: 4),
                    app("fat", cpu: 5, mem: 6 << 30, watts: 0.1)]
        let s = e.update(thermal: .fair, memory: .warning, apps: apps, at: at(0)).state
        let thermal = try #require(s.active.first { $0.id == "thermal" })
        #expect(thermal.culprit?.displayName == "hot" && thermal.culpritValue == 4)
        let memory = try #require(s.active.first { $0.id == "memory" })
        #expect(memory.culprit?.displayName == "fat" && memory.culpritValue == Double(6 << 30))
    }

    // MARK: runaway

    @Test func runawayAfterFiveMinutesAtOrAbove100() throws {
        var e = AlertEngine()
        var s = AlertState.calm
        for t in stride(from: 0.0, through: 299, by: 1) {
            s = e.update(thermal: nil, memory: nil, apps: [app("spin", cpu: 100)], at: at(t)).state
        }
        #expect(s.level == .calm)
        s = e.update(thermal: nil, memory: nil, apps: [app("spin", cpu: 150)], at: at(300)).state
        #expect(s.level == .elevated)
        #expect(s.arcs[.cpu] == .elevated)
        let a = try #require(s.active.first)
        #expect(a.id == "runaway:app:spin")
        #expect(a.culprit?.displayName == "spin")
        #expect(a.culpritValue == 150)
        #expect(a.since == at(300))
    }

    @Test func oneDipResetsTheRunawayWindow() {
        var e = AlertEngine()
        for t in stride(from: 0.0, through: 200, by: 5) { _ = e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 120)], at: at(t)) }
        _ = e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 99)], at: at(205))
        for t in stride(from: 210.0, through: 505, by: 5) { _ = e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 120)], at: at(t)) }
        #expect(e.state.level == .calm)                              // 210…505 is 295 s
        #expect(e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 120)], at: at(510)).state.level == .elevated)
    }

    @Test func runawayExitsBelow80For30Seconds() {
        var e = AlertEngine()
        for t in stride(from: 0.0, through: 300, by: 5) { _ = e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 200)], at: at(t)) }
        #expect(e.state.level == .elevated)
        #expect(e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 85)], at: at(305)).state.level == .elevated)   // hysteresis
        _ = e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 50)], at: at(310))
        #expect(e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 50)], at: at(339)).state.level == .elevated)
        #expect(e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 50)], at: at(340)).state.level == .calm)
    }

    @Test func runawayExclusionsAndNilCPU() {
        var e = AlertEngine()
        for t in stride(from: 0.0, through: 400, by: 5) {
            _ = e.update(thermal: nil, memory: nil,
                         apps: [app("system", cpu: 800, kind: .system), app("other", cpu: 800, kind: .other),
                                app("n", cpu: nil)],
                         at: at(t))
        }
        #expect(e.state == .calm)
    }

    @Test func exitedRunawayAppEndsAfterExitWindow() {
        var e = AlertEngine()
        for t in stride(from: 0.0, through: 300, by: 5) { _ = e.update(thermal: nil, memory: nil, apps: [app("x", cpu: 200)], at: at(t)) }
        _ = e.update(thermal: nil, memory: nil, apps: [], at: at(305))
        #expect(e.update(thermal: nil, memory: nil, apps: [], at: at(335)).state.level == .calm)
    }

    // MARK: events

    @Test func transitionEventsShareIdAndCloseOnExit() throws {
        var e = AlertEngine()
        let start = e.update(thermal: .fair, memory: nil, apps: [], at: at(0)).events
        let opened = try #require(start.first)
        #expect(start.count == 1)
        #expect(opened.kind == .thermalPressure && opened.end == nil && opened.level == .elevated && opened.start == at(0))
        #expect(e.update(thermal: .fair, memory: nil, apps: [], at: at(1)).events.isEmpty)
        let up = try #require(e.update(thermal: .serious, memory: nil, apps: [], at: at(2)).events.first)
        #expect(up.id == opened.id && up.level == .critical && up.end == nil)
        _ = e.update(thermal: .nominal, memory: nil, apps: [], at: at(3))
        let closed = try #require(e.update(thermal: .nominal, memory: nil, apps: [], at: at(13)).events.first)
        #expect(closed.id == opened.id && closed.end == at(13) && closed.level == .critical)
        #expect(closed.peak == Double(ThermalPressure.serious.rawValue))
    }

    @Test func runawayEventCarriesAppAndPeak() throws {
        var e = AlertEngine()
        var events: [HistoryEvent] = []
        for t in stride(from: 0.0, through: 300, by: 5) {
            events += e.update(thermal: nil, memory: nil, apps: [app("x", cpu: t == 300 ? 250 : 200)], at: at(t)).events
        }
        let ev = try #require(events.first)
        #expect(ev.kind == .runawayApp && ev.app?.displayName == "x" && ev.metric == .cpu && ev.peak == 250)
        #expect(ev.start == at(300))
    }

    // MARK: paused

    @Test func pauseClosesOpenEpisodes() throws {
        var e = AlertEngine()
        let opened = try #require(e.update(thermal: .fair, memory: nil, apps: [], at: at(0)).events.first)
        _ = e.setPaused(true, at: at(5))
        let closed = e.drainPendingEvents()
        #expect(closed.count == 1)
        #expect(closed.first?.id == opened.id && closed.first?.end == at(5))
        #expect(e.drainPendingEvents().isEmpty)
    }

    @Test func pausedIsCalmAndDimmedAndIgnoresInput() {
        var e = AlertEngine()
        _ = e.update(thermal: .critical, memory: nil, apps: [], at: at(0))
        let p = e.setPaused(true, at: at(1))
        #expect(p.level == .calm && p.paused && p.active.isEmpty)
        #expect(p.pulseToken == 1)
        #expect(e.update(thermal: .critical, memory: nil, apps: [], at: at(2)).state.level == .calm)
        let r = e.setPaused(false, at: at(3))
        #expect(!r.paused)
        #expect(e.update(thermal: .critical, memory: nil, apps: [], at: at(4)).state.level == .critical)
        #expect(e.state.pulseToken == 2)
    }
}
