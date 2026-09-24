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
/// Events: one `HistoryEvent` per episode, emitted on entry (`end == nil`), again with the same id when the episode's
/// peak level rises, and on exit with `end` set — the store upserts by id.
public struct AlertEngine: Sendable {
    private struct LevelTracker: Sendable {
        var level: AlertLevel = .calm
        var lowerSince: Date?
        var pending: AlertLevel = .calm
        var since: Date?
        var eventID: UUID?
        var peakLevel: AlertLevel = .calm
        var peakRaw: Double?
        var raw: Int?
    }

    private struct Runaway: Sendable {
        var identity: AppIdentity
        var aboveSince: Date?
        var active = false
        var since: Date?
        var belowSince: Date?
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
    /// Episode-closing events produced by `setPaused(true)`; drained by the sampling engine.
    private var pendingEvents: [HistoryEvent] = []

    public init(config: AlertConfig = .init()) {
        self.config = config
    }

    public mutating func update(thermal thermalInput: ThermalPressure?, memory memoryInput: MemoryPressureLevel?,
                                apps: [AppSample], at now: Date) -> (state: AlertState, events: [HistoryEvent]) {
        guard !state.paused else { return (state, []) }
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
        Self.step(&thermal, to: tLevel, raw: thermalInput?.rawValue, now: now, hold: config.stepDownHold,
                  kind: .thermalPressure, label: Self.thermalLabel, events: &events)
        Self.step(&memory, to: mLevel, raw: memoryInput?.rawValue, now: now, hold: config.stepDownHold,
                  kind: .memoryPressure, label: Self.memoryLabel, events: &events)
        thermalCulprit = Self.top(apps) { $0.energyWatts ?? $0.cpuPercent }
        memoryCulprit = Self.top(apps) { $0.memory.map { Double($0) } }
        updateRunaways(apps, now: now, events: &events)

        let previous = state.level
        state = buildState()
        if state.level == .critical, previous != .critical { state.pulseToken += 1 }
        return (state, events)
    }

    public mutating func setPaused(_ paused: Bool, at now: Date) -> AlertState {
        guard paused != state.paused else { return state }
        if paused {
            pendingEvents += closeAll(at: now)
        }
        thermal = LevelTracker()
        memory = LevelTracker()
        runaways.removeAll()
        state = AlertState(pulseToken: state.pulseToken, paused: paused)
        return state
    }

    /// Events produced outside `update` (episodes closed by a pause).
    mutating func drainPendingEvents() -> [HistoryEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    // MARK: - Thermal / memory

    private static func thermalLabel(_ raw: Int) -> String {
        "Thermal pressure: \(name(ThermalPressure(rawValue: raw) ?? .nominal))"
    }

    private static func memoryLabel(_ raw: Int) -> String {
        "Memory pressure: \(name(MemoryPressureLevel(rawValue: raw) ?? .normal))"
    }

    private static func step(_ t: inout LevelTracker, to condition: AlertLevel, raw: Int?, now: Date, hold: Duration,
                             kind: HistoryEvent.Kind, label: (Int) -> String, events: inout [HistoryEvent]) {
        let before = t.level
        if condition > t.level {
            t.level = condition
            t.lowerSince = nil
        } else if condition == t.level {
            t.lowerSince = nil
        } else if let since = t.lowerSince {
            t.pending = max(t.pending, condition)
            if now.timeIntervalSince(since) >= hold.seconds {
                t.level = t.pending
                t.lowerSince = nil
            }
        } else {
            t.lowerSince = now
            t.pending = condition
        }
        if let raw, Self.level(ofRaw: raw, kind: kind) == t.level { t.raw = raw }

        if before == .calm, t.level > .calm {
            t.since = now
            t.eventID = UUID()
            t.peakLevel = t.level
            t.peakRaw = raw.map(Double.init)
            events.append(event(t, kind: kind, label: label, end: nil))
        } else if t.level > .calm {
            if let raw { t.peakRaw = max(t.peakRaw ?? Double(raw), Double(raw)) }
            if t.level > t.peakLevel {
                t.peakLevel = t.level
                events.append(event(t, kind: kind, label: label, end: nil))
            }
        } else if before > .calm {
            events.append(event(t, kind: kind, label: label, end: now))
            t = LevelTracker()
        }
    }

    private static func event(_ t: LevelTracker, kind: HistoryEvent.Kind, label: (Int) -> String, end: Date?) -> HistoryEvent {
        let raw = t.peakRaw.map { Int($0) } ?? t.raw ?? 0
        return HistoryEvent(id: t.eventID ?? UUID(), kind: kind, start: t.since ?? end ?? .distantPast, end: end,
                            level: t.peakLevel, peak: t.peakRaw, label: label(raw))
    }

    private static func level(ofRaw raw: Int, kind: HistoryEvent.Kind) -> AlertLevel {
        switch kind {
        case .thermalPressure:
            switch ThermalPressure(rawValue: raw) {
            case .fair?: .elevated
            case .serious?, .critical?: .critical
            default: .calm
            }
        default:
            switch MemoryPressureLevel(rawValue: raw) {
            case .warning?: .elevated
            case .critical?: .critical
            default: .calm
            }
        }
    }

    // MARK: - Runaway apps

    private mutating func updateRunaways(_ apps: [AppSample], now: Date, events: inout [HistoryEvent]) {
        var seen = Set<AppKey>()
        for a in apps where !config.runawayExcluded.contains(a.identity.key) {
            seen.insert(a.identity.key)
            let tracked = runaways[a.identity.key] != nil
            guard tracked || (a.cpuPercent ?? 0) >= config.runawayEnterCPUPercent else { continue }
            var r = runaways[a.identity.key] ?? Runaway(identity: a.identity)
            r.identity = a.identity
            Self.advance(&r, cpu: a.cpuPercent ?? 0, now: now, config: config, events: &events)
            runaways[a.identity.key] = r
        }
        for key in Array(runaways.keys) where !seen.contains(key) {
            guard var r = runaways[key] else { continue }
            Self.advance(&r, cpu: 0, now: now, config: config, events: &events)   // exited/missing app reads 0 %
            runaways[key] = r
        }
        runaways = runaways.filter { $0.value.active || $0.value.aboveSince != nil }
    }

    private static func advance(_ r: inout Runaway, cpu: Double, now: Date, config: AlertConfig,
                                events: inout [HistoryEvent]) {
        r.cpu = cpu
        if !r.active {
            guard cpu >= config.runawayEnterCPUPercent else {
                r.aboveSince = nil
                return
            }
            let start = r.aboveSince ?? now
            r.aboveSince = start
            if now.timeIntervalSince(start) >= config.runawayEnterAfter.seconds {
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
            let below = r.belowSince ?? now
            r.belowSince = below
            if now.timeIntervalSince(below) >= config.runawayExitAfter.seconds {
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
                     label: "\(r.identity.displayName) using \(Int(r.peak.rounded())) % CPU")
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
        if thermal.level > .calm {
            out.append(Self.event(thermal, kind: .thermalPressure, label: Self.thermalLabel, end: now))
        }
        if memory.level > .calm {
            out.append(Self.event(memory, kind: .memoryPressure, label: Self.memoryLabel, end: now))
        }
        for r in runaways.values where r.active { out.append(Self.runawayEvent(r, end: now)) }
        return out
    }

    // MARK: - Helpers

    /// Top app by `value`, excluding `.system`/`.other`.
    private static func top(_ apps: [AppSample], by value: (AppSample) -> Double?) -> (AppIdentity, Double)? {
        var best: (AppIdentity, Double)?
        for a in apps where a.identity.key.kind != .system && a.identity.key.kind != .other {
            guard let v = value(a) else { continue }
            if best == nil || v > best!.1 { best = (a.identity, v) }
        }
        return best
    }

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
