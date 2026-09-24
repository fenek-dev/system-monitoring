import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Pure bindings of the popover (DESIGN §3.1–3.2): row sections, row texts, expansion lines, banners.
/// Views only lay these out, so the copy/format rules are unit-tested (`PopoverTests`).
@MainActor
enum PopoverModel {
    /// Compact rows (Power, Disk); the rest are full rows.
    static let compactCategories: Set<MonitorModel.Category> = [.power, .disk]

    /// Visible categories in `PopoverLayout` order, minus hidden, split into the full block and the compact
    /// block (the divider between blocks is dropped when either side is empty).
    static func sections(_ layout: PopoverLayout) -> (full: [MonitorModel.Category], compact: [MonitorModel.Category]) {
        var order = layout.order
        for c in MonitorModel.Category.allCases where !order.contains(c) { order.append(c) }   // tolerate stale prefs
        let visible = order.filter { !layout.hidden.contains($0) }
        return (visible.filter { !compactCategories.contains($0) }, visible.filter { compactCategories.contains($0) })
    }

    struct Row: Equatable, Identifiable {
        var id: MonitorModel.Category { category }
        var category: MonitorModel.Category
        var compact: Bool
        var subtitle: String?
        var value: String?
        var unavailableReason: String?
        var points: [SeriesPoint]
        var domain: ClosedRange<Double>
        /// Alert level of the category's arc (row fill + value color when not calm).
        var stress: AlertLevel
    }

    static func row(_ c: MonitorModel.Category, live: LiveModel, units: UnitPreferences) -> Row {
        let health = live.sensorHealth
        let reason = unavailableReason(c.headlineMetric, health: health)
        let stress = c.iconArc.flatMap { live.alert.paused ? nil : live.alert.arcs[$0] } ?? .calm
        var r = Row(category: c, compact: compactCategories.contains(c), subtitle: nil, value: nil,
                    unavailableReason: reason, points: [], domain: 0...1, stress: stress)
        switch c {
        case .cpu:
            let d = live.device
            var parts: [String] = []
            let n = d.performanceCores + d.efficiencyCores
            if n > 0 { parts.append("\(TTFormat.count(n)) cores") }
            let p = live.cpu.clusters.first { $0.kind == .performance }?.frequencyMHz
            if let p { parts.append(TTFormat.ghz(p, digits: 1)) }
            r.subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
            r.value = TTFormat.percent(live.cpu.usage)
            r.points = live.chartSeries(.cpuUsage)
        case .gpu:
            r.subtitle = live.gpu.frequencyMHz.map { TTFormat.frequency($0) }
            r.value = TTFormat.percent(live.gpu.usage)
            r.points = live.chartSeries(.gpuUsage)
        case .memory:
            r.subtitle = live.memory.pressureLevel.map { "pressure \($0.title.lowercased())" }
            r.value = TTFormat.memory(live.memory.used, style: .headline)
            r.points = live.chartSeries(.memUsed)
            r.domain = 0...Double(max(live.memory.total, 1))
        case .network:
            r.subtitle = live.network.txBps.map { TTFormat.rate($0, units: units, direction: .up) }
            r.value = TTFormat.rate(live.network.rxBps, units: units)
            r.points = live.chartSeries(.netRx)
            r.domain = W5a.rateDomain(r.points)
        case .thermals:
            r.subtitle = thermalSubtitle(live.thermals, device: live.device, stressed: stress != .calm)
            r.value = TTFormat.temperature(live.thermals.socAverage, units: units)
            r.points = live.chartSeries(.socTemp)
            r.domain = 0...100
        case .power:
            r.subtitle = live.power.battery == nil && live.device.hasBattery ? nil : W5a.batteryPhrase(live.power.battery)
            // Package from IOReport; if the Energy Model is missing, the SMC system power so the row never
            // shows "—" while the Mac reports its draw (CP2).
            let w = W5a.packageWatts(live.power) ?? live.power.systemWatts
            r.value = TTFormat.watts(w)
            if w != nil { r.unavailableReason = nil }
        case .disk:
            r.subtitle = TTFormat.ratePair(read: live.disk.readBps, write: live.disk.writeBps)
            if let v = live.disk.bootVolume {
                r.value = ShellFormat.freeSpace(v)   // one owner of the free-space rule (W4)
                r.unavailableReason = nil
            } else {
                r.unavailableReason = reason ?? "Boot volume not reported"
            }
        }
        return r
    }

    /// Calm "Nominal · 2,140 rpm"; stressed "Fair · fans 3,900 rpm"; no fans "Nominal · no fans".
    static func thermalSubtitle(_ t: ThermalSnapshot, device: DeviceInfo, stressed: Bool) -> String? {
        var parts: [String] = []
        if let p = t.pressure { parts.append(p.title) }
        if device.fanCount == 0 {
            parts.append("no fans")
        } else if let rpm = W5a.averageFanRPM(t.fans) {
            parts.append((stressed ? "fans " : "") + TTFormat.rpm(rpm))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Expansion

    /// Top 3 app groups for the category's key (ARCHITECTURE §5.5, cached per apply by `LiveModel`); `TTPopoverRow`
    /// formats the DESIGN §2.22 metric per line.
    static func expansionApps(_ c: MonitorModel.Category, live: LiveModel) -> [AppSample] {
        live.topApps(c, count: 3)
    }

    // MARK: Top consumer

    struct Consumer: Equatable {
        var app: AppSample
        var detail: String
    }

    /// Calm: the app group with the highest CPU (DESIGN §3.1 binding; not `LiveModel.topConsumer`, which ranks by
    /// energy), detail "212% CPU · 3.8 GB". With an alert: its culprit, detail "96% CPU · 41% GPU" (DESIGN §3.2).
    static func consumer(live: LiveModel) -> Consumer? {
        if let alert = live.alert.active.first, !live.alert.paused, let key = alert.culprit?.key,
           let app = live.app(key) {
            let parts = [TTFormat.cpuPercentInteger(app.cpuPercent) + " CPU",
                         TTFormat.cpuPercentInteger(app.gpuPercent) + " GPU"]
            return Consumer(app: app, detail: parts.joined(separator: " · "))
        }
        // The whole CPU ranking (cached per apply), first non-system group; no energy fallback (DESIGN §3.1).
        guard let app = live.topApps(.cpu, count: Int.max).first(where: { $0.identity.key.kind != .system })
        else { return nil }
        let parts = [TTFormat.cpuPercentInteger(app.cpuPercent) + " CPU",
                     TTFormat.memory(app.memory, style: .headline)]
        return Consumer(app: app, detail: parts.joined(separator: " · "))
    }

    // MARK: Banners

    struct Banner: Equatable, Identifiable {
        enum Action: Equatable, Sendable { case show(DashboardPage), quit(AppKey) }
        struct Button: Equatable, Sendable {
            var title: String
            var action: Action
        }
        var id: String
        var level: AlertLevel
        var message: String
        var buttons: [Button]
    }

    /// One banner per active alert, most severe first (DESIGN §3.2). "Quit {App}" only for user-owned apps.
    static func banners(live: LiveModel, units: UnitPreferences, canControl: (ProcessTarget) -> Bool) -> [Banner] {
        guard !live.alert.paused else { return [] }
        return live.alert.active.map { alert in
            let app = alert.culprit.flatMap { live.app($0.key) }
            let name = app?.name ?? alert.culprit?.displayName
            var message: String
            var show: (String, DashboardPage)
            switch alert.kind {
            case .thermalPressure:
                let t = TTFormat.temperature(live.thermals.socAverage, units: units)
                let tail = "Performance cores may slow down to cool off."
                // The artboard breaks the line between the two sentences.
                message = name.map { "\($0) is pushing the SoC to \(t).\n\(tail)" } ?? "The SoC is at \(t).\n\(tail)"
                show = ("Show Thermals", .thermals)
            case .memoryPressure(let level):
                let word = level == .critical ? "critical" : "high"
                message = "Memory pressure is \(word)."
                if let name { message += " \(name) is using \(TTFormat.memory(app?.memory, style: .headline))." }
                show = ("Show Memory", .memory)
            case .runawayApp(_, let pct):
                let n = TTFormat.cpuPercentInteger(pct)
                let dur = TTFormat.duration(.seconds(max(0, (live.lastUpdate ?? alert.since).timeIntervalSince(alert.since))))
                message = "\(name ?? "An app") has used \(n) CPU for \(dur)."
                show = ("Show Processes", .processes)
            }
            var buttons = [Banner.Button(title: show.0, action: .show(show.1))]
            if let app, app.isCurrentUser, canControl(app.target) {
                buttons.append(Banner.Button(title: "Quit \(app.name)", action: .quit(app.identity.key)))
            }
            return Banner(id: alert.id, level: alert.level, message: message, buttons: buttons)
        }
    }

    /// Row expansion toggle (several rows may be open at once).
    static func toggled(_ open: Set<MonitorModel.Category>, _ c: MonitorModel.Category) -> Set<MonitorModel.Category> {
        var s = open
        if s.contains(c) { s.remove(c) } else { s.insert(c) }
        return s
    }

    /// Feedback line for a failed Quit (ARCHITECTURE §6.7: failures → toast); nil on success/cancel.
    static func feedback(_ result: ActionResult, name: String) -> String? {
        switch result {
        case .done, .cancelled: nil
        case .notPermitted: "Not permitted to quit \(name)"
        case .failed(let why): "Couldn't quit \(name): \(why)"
        }
    }
}

/// Everything the popover does, in one place so behaviour is testable without driving SwiftUI gestures.
@MainActor
struct PopoverActions {
    var commands: AppCommands
    var actions: ProcessActions
    var live: LiveModel

    func openApp(_ key: AppKey) { commands.inspectApp(key) }
    func openDashboard() { commands.openDashboard(.overview) }
    func openHistory() { commands.openDashboard(.history) }
    func openSettings() { commands.openSettings() }
    func quitTelltale() { commands.quitTelltale() }
    func setPaused(_ paused: Bool) { commands.setPaused(paused) }

    /// Quits an app group; returns the feedback text for a failure.
    func quit(_ app: AppSample) async -> String? {
        PopoverModel.feedback(await actions.quit(app.target), name: app.name)
    }

    /// Banner button; returns feedback text for a failed Quit.
    func perform(_ action: PopoverModel.Banner.Action) async -> String? {
        switch action {
        case .show(let page):
            commands.openDashboard(page)
            return nil
        case .quit(let key):
            guard let app = live.app(key) else { return nil }
            return await quit(app)
        }
    }
}
