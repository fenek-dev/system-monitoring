import Foundation
import MonitorModel

/// Alert state machine (ARCHITECTURE §5.8):
///
/// | Input | Level | Arc |
/// |---|---|---|
/// | thermal nominal / fair / serious / critical | calm / elevated / critical / critical | thermals |
/// | memory normal / warning / critical | calm / elevated / critical | memory |
/// | runaway app (≥ 100 % for 5 min) | elevated | cpu |
/// | input `nil` | calm (never raises) | — |
/// | paused | calm, `paused = true` | — |
///
/// Thermal/memory: step-up immediate; step-down after `stepDownHold` of continuously lower input, to the highest
/// level seen during the hold. Runaway: enters when every sample over `runawayEnterAfter` is ≥ the enter threshold,
/// exits after `runawayExitAfter` continuously below the exit threshold (an exited app reads 0 %).
///
/// Timers (ruling, ICR-9): holds and windows run on monotonic uptime; `Date` only stamps events and `since`.
/// A gap between samples of more than 2× the nominal interval (sleep/wake, stalls; checked on uptime and wall clock)
/// restarts every pending hold and window.
///
/// Events: one `HistoryEvent` per episode, emitted on entry (`end == nil`), again with the same id when the episode's
/// peak level rises, and on exit with `end` set — the store upserts by id.
public struct AlertEngine: Sendable {
    private struct LevelTracker: Sendable {
        var level: AlertLevel = .calm
        var lowerSince: Double?          // uptime seconds
        var pending: AlertLevel = .calm
        var since: Date?
        var eventID: UUID?
        var peakLevel: AlertLevel = .calm
        var peakRaw: Double?
        var raw: Int?
    }

    private struct Runaway: Sendable {
        var identity: AppIdentity
        var aboveSince: Double?          // uptime seconds
        var active = false
        var since: Date?
        var belowSince: Double?          // uptime seconds
        var cpu: Double = 0
        var peak: Double = 0
        var eventID = UUID()
    }

    public let config: AlertConfig
    public private(set) var state: AlertState = .calm
    private var thermal = LevelTracker()
    private var memory = LevelTracker()
    private var runaways: [AppKey: Runaway] = [:]
    private var thermalCulprit: (AppIdentity, Double)?
    private var memoryCulprit: (AppIdentity, Double)?
    private var last: (uptime: Double, wall: Date, nominal: Duration?)?
    /// Episode-closing events produced by `setPaused(true)`; drained by the sampling engine.
    private var pendingEvents: [HistoryEvent] = []

    public init(config: AlertConfig = .init()) {
        self.config = config
    }

    /// Locked §5.8 signature: `now` doubles as the monotonic clock and no gap detection runs.
    /// The sampling engine uses `update(thermal:memory:apps:at:uptimeNs:nominalInterval:)`.
    public mutating func update(thermal: ThermalPressure?, memory: MemoryPressureLevel?, apps: [AppSample],
                                at now: Date) -> (state: AlertState, events: [HistoryEvent]) {
        let t = now.timeIntervalSince1970
        return update(thermal: thermal, memory: memory, apps: apps, at: now,
                      uptimeNs: t > 0 ? UInt64(t * 1e9) : 0, nominalInterval: nil)
    }

    /// ICR-9: timers on `uptimeNs`; `nominalInterval` (the mode's interval) enables gap detection.
    public mutating func update(thermal thermalInput: ThermalPressure?, memory memoryInput: MemoryPressureLevel?,
                                apps: [AppSample], at now: Date, uptimeNs: UInt64,
                                nominalInterval: Duration?) -> (state: AlertState, events: [HistoryEvent]) {
        guard !state.paused else { return (state, []) }
        let clock = Double(uptimeNs) / 1e9
        if let last, let nominal = nominalInterval {
            let allowed = 2 * max(nominal, last.nominal ?? nominal).seconds
            let wallGap = now.timeIntervalSince(last.wall)
            if clock - last.uptime > allowed || wallGap > allowed { restartTimers() }
        }
        last = (clock, now, nominalInterval)

        var events: [HistoryEvent] = []
        let tLevel: AlertLevel = switch thermalInput {
        case nil, .nominal?: .calm
        case .fair?: .elevated
        case .serious?, .critical?: .critical
        }
        let mLevel: AlertLevel = switch memoryInput {
        case nil, .normal?: .calm
        case .warning?: .elevated
        case .critical?: .critical
        }
        Self.step(&thermal, to: tLevel, raw: thermalInput?.rawValue, now: now, clock: clock, hold: config.stepDownHold,
                  kind: .thermalPressure, events: &events)
        Self.step(&memory, to: mLevel, raw: memoryInput?.rawValue, now: now, clock: clock, hold: config.stepDownHold,
                  kind: .memoryPressure, events: &events)
        thermalCulprit = topThermal(apps)
        memoryCulprit = top(apps) { $0.memory.map { Double($0) } }
        updateRunaways(apps, now: now, clock: clock, events: &events)

        let previous = state.level
        state = buildState()
        if state.level == .critical, previous != .critical { state.pulseToken += 1 }
        return (state, events)
    }

    public mutating func setPaused(_ paused: Bool, at now: Date) -> AlertState {
        guard paused != state.paused else { return state }
        if paused { pendingEvents += closeAll(at: now) }
        thermal = LevelTracker()
        memory = LevelTracker()
        runaways.removeAll()
        last = nil
        state = AlertState(pulseToken: state.pulseToken, paused: paused)
        return state
    }

    /// Events produced outside `update` (episodes closed by a pause).
    mutating func drainPendingEvents() -> [HistoryEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    private mutating func restartTimers() {
        thermal.lowerSince = nil
        memory.lowerSince = nil
        for key in Array(runaways.keys) {
            runaways[key]?.aboveSince = nil
            runaways[key]?.belowSince = nil
        }
    }

    // MARK: - Thermal / memory

    private static func label(_ kind: HistoryEvent.Kind, _ raw: Int) -> String {
        // DESIGN History chips: "Thermal: Fair", "{App} CPU spike".
        kind == .thermalPressure
            ? "Thermal: \(name(ThermalPressure(rawValue: raw) ?? .nominal))"
            : "Memory: \(name(MemoryPressureLevel(rawValue: raw) ?? .normal))"
    }

    private static func step(_ t: inout LevelTracker, to condition: AlertLevel, raw: Int?, now: Date, clock: Double,
                             hold: Duration, kind: HistoryEvent.Kind, events: inout [HistoryEvent]) {
        let before = t.level
        if condition > t.level {
            t.level = condition
            t.lowerSince = nil
        } else if condition == t.level {
            t.lowerSince = nil
        } else if let since = t.lowerSince {
            t.pending = max(t.pending, condition)
            if clock - since >= hold.seconds {
                t.level = t.pending
                t.lowerSince = nil
            }
        } else {
            t.lowerSince = clock
            t.pending = condition
        }
        // The alert's kind always matches its level: latest raw input of that level, else the level's canonical input.
        if let raw, level(ofRaw: raw, kind: kind) == t.level {
            t.raw = raw
        } else if t.level > .calm, t.raw.map({ level(ofRaw: $0, kind: kind) }) != t.level {
            t.raw = canonicalRaw(t.level, kind: kind)
        }

        if before == .calm, t.level > .calm {
            t.since = now
            t.eventID = UUID()
            t.peakLevel = t.level
            t.peakRaw = raw.map(Double.init)
            events.append(event(t, kind: kind, end: nil))
        } else if t.level > .calm {
            if let raw { t.peakRaw = max(t.peakRaw ?? Double(raw), Double(raw)) }
            if t.level > t.peakLevel {
                t.peakLevel = t.level
                events.append(event(t, kind: kind, end: nil))
            }
        } else if before > .calm {
            events.append(event(t, kind: kind, end: now))
            t = LevelTracker()
        }
    }

    private static func event(_ t: LevelTracker, kind: HistoryEvent.Kind, end: Date?) -> HistoryEvent {
        let raw = t.peakRaw.map { Int($0) } ?? t.raw ?? 0
        return HistoryEvent(id: t.eventID ?? UUID(), kind: kind, start: t.since ?? end ?? .distantPast, end: end,
                            level: t.peakLevel, peak: t.peakRaw, label: label(kind, raw))
    }

    private static func level(ofRaw raw: Int, kind: HistoryEvent.Kind) -> AlertLevel {
        if kind == .thermalPressure {
            switch ThermalPressure(rawValue: raw) {
            case .fair?: return .elevated
            case .serious?, .critical?: return .critical
            default: return .calm
            }
        }
        switch MemoryPressureLevel(rawValue: raw) {
        case .warning?: return .elevated
        case .critical?: return .critical
        default: return .calm
        }
    }

    private static func canonicalRaw(_ level: AlertLevel, kind: HistoryEvent.Kind) -> Int {
        if kind == .thermalPressure {
            return (level == .critical ? ThermalPressure.serious : level == .elevated ? .fair : .nominal).rawValue
        }
        return (level == .critical ? MemoryPressureLevel.critical : level == .elevated ? .warning : .normal).rawValue
    }

    // MARK: - Runaway apps

    private func excluded(_ key: AppKey) -> Bool {
        key.kind == .system || key.kind == .other || config.runawayExcluded.contains(key)
    }

    private mutating func updateRunaways(_ apps: [AppSample], now: Date, clock: Double, events: inout [HistoryEvent]) {
        var seen = Set<AppKey>()
        for a in apps where !excluded(a.identity.key) {
            seen.insert(a.identity.key)
            let tracked = runaways[a.identity.key] != nil
            guard tracked || (a.cpuPercent ?? 0) >= config.runawayEnterCPUPercent else { continue }
            var r = runaways[a.identity.key] ?? Runaway(identity: a.identity)
            r.identity = a.identity
            Self.advance(&r, cpu: a.cpuPercent ?? 0, now: now, clock: clock, config: config, events: &events)
            runaways[a.identity.key] = r
        }
        for key in Array(runaways.keys) where !seen.contains(key) {
            guard var r = runaways[key] else { continue }
            Self.advance(&r, cpu: 0, now: now, clock: clock, config: config, events: &events)   // exited app reads 0 %
            runaways[key] = r
        }
        runaways = runaways.filter { $0.value.active || $0.value.aboveSince != nil }
    }

    private static func advance(_ r: inout Runaway, cpu: Double, now: Date, clock: Double, config: AlertConfig,
                                events: inout [HistoryEvent]) {
        r.cpu = cpu
        if !r.active {
            guard cpu >= config.runawayEnterCPUPercent else {
                r.aboveSince = nil
                return
            }
            let start = r.aboveSince ?? clock
            r.aboveSince = start
            if clock - start >= config.runawayEnterAfter.seconds {
                r.active = true
                r.since = now
                r.peak = cpu
                r.eventID = UUID()
                events.append(runawayEvent(r, end: nil))
            }
            return
        }
        r.peak = max(r.peak, cpu)
        if cpu < config.runawayExitCPUPercent {
            let below = r.belowSince ?? clock
            r.belowSince = below
            if clock - below >= config.runawayExitAfter.seconds {
                events.append(runawayEvent(r, end: now))
                r = Runaway(identity: r.identity)
            }
        } else {
            r.belowSince = nil
        }
    }

    private static func runawayEvent(_ r: Runaway, end: Date?) -> HistoryEvent {
        HistoryEvent(id: r.eventID, kind: .runawayApp, start: r.since ?? end ?? .distantPast, end: end, level: .elevated,
                     app: r.identity, metric: .cpu, peak: r.peak,
                     label: "\(r.identity.displayName) CPU spike")
    }

    // MARK: - State

    private func buildState() -> AlertState {
        var s = AlertState(pulseToken: state.pulseToken)
        var active: [ActiveAlert] = []
        if thermal.level > .calm {
            active.append(ActiveAlert(kind: .thermalPressure(ThermalPressure(rawValue: thermal.raw ?? 0) ?? .nominal),
                                      level: thermal.level, arc: .thermals, since: thermal.since ?? .distantPast,
                                      culprit: thermalCulprit?.0, culpritValue: thermalCulprit?.1))
        }
        if memory.level > .calm {
            active.append(ActiveAlert(kind: .memoryPressure(MemoryPressureLevel(rawValue: memory.raw ?? 1) ?? .normal),
                                      level: memory.level, arc: .memory, since: memory.since ?? .distantPast,
                                      culprit: memoryCulprit?.0, culpritValue: memoryCulprit?.1))
        }
        for r in runaways.values where r.active {
            active.append(ActiveAlert(kind: .runawayApp(r.identity.key, cpuPercent: r.cpu), level: .elevated, arc: .cpu,
                                      since: r.since ?? .distantPast, culprit: r.identity, culpritValue: r.cpu))
        }
        active.sort { a, b in
            if a.level != b.level { return a.level > b.level }
            if a.since != b.since { return a.since < b.since }
            return a.id < b.id
        }
        s.arcs[.thermals] = thermal.level
        s.arcs[.memory] = memory.level
        s.arcs[.cpu] = active.contains { $0.arc == .cpu } ? .elevated : .calm
        s.level = s.arcs.values.max() ?? .calm
        s.active = active
        return s
    }

    private mutating func closeAll(at now: Date) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        if thermal.level > .calm { out.append(Self.event(thermal, kind: .thermalPressure, end: now)) }
        if memory.level > .calm { out.append(Self.event(memory, kind: .memoryPressure, end: now)) }
        for r in runaways.values where r.active { out.append(Self.runawayEvent(r, end: now)) }
        return out
    }

    // MARK: - Culprits

    /// Candidates exclude `.system`/`.other`.
    private func candidates(_ apps: [AppSample]) -> [AppSample] {
        apps.filter { $0.identity.key.kind != .system && $0.identity.key.kind != .other }
    }

    private func top(_ apps: [AppSample], by value: (AppSample) -> Double?) -> (AppIdentity, Double)? {
        var best: (AppIdentity, Double)?
        for a in candidates(apps) {
            guard let v = value(a) else { continue }
            if best == nil || v > best!.1 { best = (a.identity, v) }
        }
        return best
    }

    /// By energy when every candidate with CPU data also has energy, else by CPU — never mixing W with %.
    private func topThermal(_ apps: [AppSample]) -> (AppIdentity, Double)? {
        let c = candidates(apps).filter { $0.energyWatts != nil || $0.cpuPercent != nil }
        guard !c.isEmpty else { return nil }
        return c.allSatisfy({ $0.energyWatts != nil }) ? top(c) { $0.energyWatts } : top(c) { $0.cpuPercent }
    }

    // MARK: - Names

    static func name(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    static func name(_ m: MemoryPressureLevel) -> String {
        switch m {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

extension Duration {
    /// Seconds as Double.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}
