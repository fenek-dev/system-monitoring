import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.10 Power & Battery: stat strip (6) · Power by component (span 2) + Battery · Energy impact (flex).
/// Energy values are average watts (§5.6); estimated rows carry an "Estimated" tooltip (ICR-8). No App Nap column.
public struct PowerPage: View {
    @State private var feedback: ProcessActionFeedback
    private let initialSelection: String?

    public init() {
        _feedback = State(initialValue: ProcessActionFeedback())
        initialSelection = nil
    }

    /// Tests/renders: start with an energy row selected (e.g. "app:app:com.apple.FinalCut") and/or inject the
    /// action feedback (toast).
    init(selectedRowID: String?, feedback: ProcessActionFeedback = ProcessActionFeedback()) {
        _feedback = State(initialValue: feedback)
        initialSelection = selectedRowID
    }

    /// The root reads no live data (the subtitle lives in its own view), so it isn't re-evaluated per tick.
    public var body: some View {
        SystemPageColumn {
            PowerStatStrip()
            SystemGrid3Row(minHeight: 285) {
                PowerByComponentCard()
                BatteryCard()
            }
            EnergyImpactCard(selection: initialSelection, feedback: feedback)
        }
        .processActionFeedback(feedback)
        .background(PowerHeaderSubtitle())
    }
}

/// Sets the header subtitle from `live.power` (only this view re-evaluates when power changes).
private struct PowerHeaderSubtitle: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        Color.clear.pageHeader(subtitle: PowerCopy.subtitle(live.power, hasBattery: live.device.hasBattery))
    }
}

// MARK: - Copy

enum PowerCopy {
    /// "On battery · 72.4 Wh · Low Power Mode off" / "On power adapter · 96 W · …" (DESIGN §3.10 header).
    /// A laptop whose battery reading is missing (sensor unavailable) doesn't claim a power source unless the adapter
    /// wattage says so.
    static func subtitle(_ p: PowerSnapshot, hasBattery: Bool) -> String {
        var parts: [String] = []
        let adapter = p.adapterWatts.map { "On power adapter · \(TTFormat.number($0, digits: 0)) W" }
        if let b = p.battery {
            parts.append(b.onAC ? (adapter ?? "On power adapter") : "On battery")
        } else if !hasBattery {
            parts.append(adapter ?? "On power adapter")
        } else if let adapter {
            parts.append(adapter)
        }
        if let wh = p.battery?.designCapacityWh { parts.append("\(TTFormat.number(wh, digits: 1)) Wh") }
        parts.append(p.lowPowerMode ? "Low Power Mode on" : "Low Power Mode off")
        return parts.joined(separator: " · ")
    }

    /// Battery drain stat: "−18.9 W" on battery, "+12.0 W" charging, "0.0 W" on the adapter (DESIGN §3.10).
    static func drain(_ b: BatterySnapshot) -> String? {
        guard let w = b.drainWatts, w.isFinite else { return nil }
        if b.onAC {
            let charge = b.isCharging ? abs(w) : 0
            return charge >= 0.05 ? "+" + TTFormat.watts(charge) : TTFormat.watts(0)
        }
        return TTFormat.watts(-abs(w))
    }

    /// Battery card caption (§5.8): "On battery · about 5 h 40 m left" / "Charging · full in 1 h 10 m" / "Charged".
    /// ICR-15: while macOS is still estimating (`timeRemainingCalculating`) the time part reads "Calculating…".
    static func batteryPhrase(_ b: BatterySnapshot) -> String {
        let calculating = b.timeRemainingCalculating && b.timeRemaining == nil
        if b.isCharging {
            if calculating { return "Charging · Calculating…" }
            return b.timeRemaining.map { "Charging · full in \(TTFormat.duration($0))" } ?? "Charging"
        }
        if b.onAC { return (b.percent ?? 0) >= 99.5 ? "Charged" : "On power adapter" }
        if calculating { return "On battery · Calculating…" }
        return b.timeRemaining.map { "On battery · about \(TTFormat.duration($0)) left" } ?? "On battery"
    }

    /// "Not connected" / "96 W USB-C" / "Connected". Without a battery reading and without adapter details the
    /// connection state is unknown → nil ("—").
    static func adapter(_ p: PowerSnapshot) -> String? {
        if let b = p.battery, !b.onAC { return "Not connected" }
        let watts = p.adapterWatts.map { "\(TTFormat.number($0, digits: 0)) W" }
        let parts = [watts, p.adapterName].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return p.battery == nil ? nil : "Connected"
    }

    /// Why battery values are "—": no battery (desktop), else the battery sensor's reason.
    static func batteryReason(hasBattery: Bool, status: SensorStatus) -> String {
        guard hasBattery else { return "This Mac has no battery" }
        return status.reason ?? "Not reported by the battery"
    }

    /// Glyph fill: `battery`, `statusElevated` at ≤ 20 %, `statusCritical` at ≤ 10 % (ADDED).
    static func fillColor(percent: Double) -> Color {
        if percent <= 10 { return TTColor.statusCritical }
        if percent <= 20 { return TTColor.statusElevated }
        return TTColor.battery
    }
}

// MARK: - Stat strip

private struct PowerStatStrip: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let p = live.power
        let h = live.sensorHealth
        TTStatStrip([
            .init(id: "package", label: "Package", value: p.packageWatts.map { TTFormat.watts($0) }, detail: "SoC total",
                  tint: TTColor.power, unavailableReason: unavailableReason(.packageWatts, health: h)),
            .init(id: "cpu", label: "CPU", value: p.cpuWatts.map { TTFormat.watts($0) },
                  unavailableReason: unavailableReason(.cpuWatts, health: h)),
            .init(id: "gpu", label: "GPU", value: p.gpuWatts.map { TTFormat.watts($0) },
                  unavailableReason: unavailableReason(.gpuWatts, health: h)),
            .init(id: "ane", label: "Neural Engine", value: p.aneWatts.map { TTFormat.watts($0) },
                  unavailableReason: unavailableReason(.aneWatts, health: h)),
            .init(id: "dram", label: "DRAM", value: p.dramWatts.map { TTFormat.watts($0) },
                  unavailableReason: unavailableReason(.dramWatts, health: h)),
            .init(id: "drain", label: "Battery drain", value: p.battery.flatMap(PowerCopy.drain), detail: "system total",
                  unavailableReason: PowerCopy.batteryReason(hasBattery: live.device.hasBattery,
                                                             status: live.status(of: .battery))),
        ])
    }
}

// MARK: - Power by component

private struct PowerByComponentCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.now) private var fixedNow
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]

    private static let metrics: [HistoryMetric] = [.cpuWatts, .gpuWatts, .aneWatts, .dramWatts]

    var body: some View {
        let range = nav.range
        let end = fixedNow ?? live.lastUpdate ?? Date()
        let points = { (m: HistoryMetric) in SystemRangeSeries.points(m, range: range, live: live, stored: stored) }
        let series = [
            ChartSeries(id: "cpu", label: "CPU", color: TTColor.cpu, points: points(.cpuWatts),
                        fillOpacity: TTChartFill.powerCPU),
            ChartSeries(id: "gpu", label: "GPU", color: TTColor.gpu, points: points(.gpuWatts),
                        fillOpacity: TTChartFill.powerGPU),
            ChartSeries(id: "ane", label: "ANE", color: TTColor.power, points: points(.aneWatts),
                        fillOpacity: TTChartFill.powerANE),
            ChartSeries(id: "dram", label: "DRAM", color: TTColor.dram, points: points(.dramWatts),
                        fillOpacity: TTChartFill.powerDRAM),
        ]
        let stacked = PowerChartScale.stackable(series)
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Power by component") { TTLegend(series) }
            Group {
                if stacked.isEmpty, let reason = unavailableReason(.cpuWatts, health: live.sensorHealth) {
                    SystemChartUnavailable(reason: reason)
                } else {
                    TTStackedArea(stacked, yDomain: 0...PowerChartScale.ceiling(stacked.map(\.points)))
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            TTTimeAxis(range: range, end: end)
        }
        .rangeSeries(Self.metrics, range: range, end: end, into: $stored)
    }
}

enum PowerChartScale {
    /// Series that go into the stack: missing samples (nil, non-finite, negative) are gaps, never 0; a component
    /// with no samples at all (not reported on this Mac) is left out so it doesn't blank the layers above it.
    static func stackable(_ series: [ChartSeries]) -> [ChartSeries] {
        series.compactMap { s in
            var s = s
            s.points = s.points.map { p in
                guard let v = p.value, v.isFinite, v >= 0 else { return SeriesPoint(time: p.time, value: nil) }
                return p
            }
            return ChartSegments.sampleCount(s.points) == 0 ? nil : s
        }
    }

    /// DESIGN §5.10: smallest nice ceiling ≥ the window's max stacked total (minimum 1 W).
    static func ceiling(_ series: [[SeriesPoint]]) -> Double {
        let n = series.map(\.count).max() ?? 0
        var peak = 0.0
        for i in 0..<n {
            var sum = 0.0
            for s in series {
                let j = i - (n - s.count)                         // align on the newest samples
                if j >= 0, let v = s[j].value, v.isFinite { sum += max(0, v) }
            }
            peak = max(peak, sum)
        }
        return TTFormat.niceCeiling(peak, minimum: 1)
    }
}

// MARK: - Battery

private struct BatteryCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units

    var body: some View {
        let p = live.power
        TTCard(spacing: TTSpace.x8) {
            HStack(spacing: TTSpace.x8) {
                TTIcon(.battery, size: 16, color: TTColor.battery)
                Text("Battery").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20)
            // "No battery" only on Macs without one; a laptop whose battery sensor is down keeps the layout with
            // "—" + the sensor's reason.
            if p.battery != nil || live.device.hasBattery {
                let b = p.battery
                let missing = b == nil ? PowerCopy.batteryReason(hasBattery: true, status: live.status(of: .battery)) : nil
                let notReported = missing ?? Self.notReported
                HStack(spacing: TTSpace.x14) {
                    BatteryGlyph(percent: b?.percent)
                    VStack(alignment: .leading, spacing: 0) {
                        MetricValue(b?.percent.map { TTFormat.percent($0 / 100) },
                                    unavailableReason: missing ?? unavailableReason(.batteryPercent, health: live.sensorHealth),
                                    font: TTFont.title1)
                            .foregroundStyle(TTColor.textPrimary)
                        Text(b.map(PowerCopy.batteryPhrase) ?? "Battery status unavailable")
                            .font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                            .helpIfPresent(missing)
                    }
                }
                // Spacer inside (not a card child) so the stretch adds no extra 8-pt card gap.
                VStack(spacing: 0) {
                    TTKeyValueList(rows: [
                        .init("Health", b?.healthFraction.map { "\(TTFormat.percent($0)) maximum capacity" },
                              unavailableReason: notReported),
                        .init("Condition", b?.condition, unavailableReason: notReported),
                        .init("Cycle count", b?.cycleCount.map { TTFormat.count($0) }, unavailableReason: notReported),
                        .init("Capacity", b.flatMap(Self.capacity), unavailableReason: notReported),
                        .init("Temperature", b?.temperatureC.map { TTFormat.temperature($0, units: units) },
                              unavailableReason: notReported),
                        // Adapter state doesn't come from the battery sensor.
                        .init("Power adapter", PowerCopy.adapter(p)),
                    ])
                    Spacer(minLength: 0)
                }
            } else {
                TTEmptyState(.empty("No battery")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private static let notReported = "Not reported by the battery"

    static func capacity(_ b: BatterySnapshot) -> String? {
        guard b.maxCapacityWh != nil, b.designCapacityWh != nil else { return nil }
        return TTFormat.wattHours(b.maxCapacityWh, of: b.designCapacityWh)
    }
}

/// DESIGN §3.10 large battery glyph: 84×38, radius 9, 2-pt border white @ 0.4, padding 3; inner fill radius 5,
/// width = charge %.
private struct BatteryGlyph: View {
    let percent: Double?

    var body: some View {
        let fraction = min(max((percent ?? 0) / 100, 0), 1)
        RoundedRectangle(cornerRadius: TTRadius.r9, style: .continuous)
            .strokeBorder(Color.white.opacity(0.4), lineWidth: TTStroke.batteryOutline)
            .frame(width: 84, height: 38)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: TTRadius.r5, style: .continuous)
                        .fill(PowerCopy.fillColor(percent: percent ?? 100))
                        .frame(width: geo.size.width * fraction)
                }
                .padding(TTStroke.batteryOutline + 3)
            }
            .accessibilityLabel(percent.map { "Battery \(TTFormat.percent($0 / 100))" } ?? "Battery unavailable")
    }
}

// MARK: - Energy impact

/// One Energy-impact row: an app group (depth 0) or one of its processes (child).
struct EnergyRow: Identifiable, Equatable {
    var id: String
    var name: String
    var identity: AppIdentity?
    var watts: Double?
    var estimated: Bool
    var reason: String?
    var average12h: Double?
    var isChild: Bool
    var preventsSleep: Bool
    var target: ProcessTarget
}

enum EnergyRows {
    /// App groups with energy > 0 or a sleep assertion (or an unavailable value to explain), excluding "Other";
    /// sorted by energy, descending (nil last, stable).
    static func apps(_ apps: [AppSample], averages: [AppKey: Double], health: [SensorID: SensorStatus]) -> [EnergyRow] {
        SystemPageSort.descending(rows(apps, averages: averages, health: health)) { $0.watts }
    }

    private static func rows(_ apps: [AppSample], averages: [AppKey: Double],
                             health: [SensorID: SensorStatus]) -> [EnergyRow] {
        apps.compactMap { a in
            guard a.identity.key != .other else { return nil }
            let reason = unavailableReason(.energy, a, health: health)
            guard (a.energyWatts ?? 0) > 0 || a.preventsSleep || reason != nil else { return nil }
            return EnergyRow(id: "app:\(a.identity.key)", name: a.identity.displayName, identity: a.identity,
                             watts: a.energyWatts, estimated: a.energyEstimated, reason: reason,
                             average12h: averages[a.identity.key], isChild: false, preventsSleep: a.preventsSleep,
                             target: a.target)
        }
    }

    static func process(_ p: ProcessSample, identity: AppIdentity?, health: [SensorID: SensorStatus]) -> EnergyRow {
        EnergyRow(id: "pid:\(p.id.pid):\(p.id.startTimeUs)", name: p.name, identity: nil, watts: p.energyWatts,
                  estimated: p.energyEstimated, reason: unavailableReason(.energy, p, health: health), average12h: nil,
                  isChild: true, preventsSleep: p.preventsSleep,
                  target: p.target)
    }
}

private struct EnergyImpactCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var fixedNow
    @State private var selection: String?
    @State private var averages: [AppKey: Double] = [:]
    let feedback: ProcessActionFeedback

    init(selection: String? = nil, feedback: ProcessActionFeedback) {
        _selection = State(initialValue: selection)
        self.feedback = feedback
    }

    var body: some View {
        let health = live.sensorHealth
        let rows = EnergyRows.apps(live.apps, averages: averages, health: health)
        let children = childMap(rows, health: health)
        let sleepReason = sleepUnavailableReason
        let end = fixedNow ?? live.lastUpdate ?? Date()
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Energy impact") {
                HStack(spacing: TTSpace.x12) {
                    ProcessActionToast(feedback: feedback)
                    TTLink("All processes") {
                        nav.processesMode = .apps
                        nav.page = .processes
                    }
                }
            }
            SystemFittedRows(rowHeight: TTTableStyle.standard.rowHeight) { limit in
                TTTable(rows: Array(rows.prefix(limit)), columns: columns(sleepReason: sleepReason),
                        selection: $selection, sort: .constant((column: "energy", descending: true)),
                        rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                        children: { children[$0.id] ?? [] },
                        style: TTTableStyle(emptyMessage: "No app energy use"))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: Int(end.timeIntervalSince1970 / 60)) { await loadAverages(end: end) }
    }

    /// Child process rows for apps with more than one process (Processes Apps-mode disclosure).
    private func childMap(_ rows: [EnergyRow], health: [SensorID: SensorStatus]) -> [String: [EnergyRow]] {
        var children: [String: [EnergyRow]] = [:]
        for row in rows {
            guard case .app(let identity, _) = row.target else { continue }
            let procs = live.processes(of: identity.key)
            if procs.count > 1 { children[row.id] = procs.map { EnergyRows.process($0, identity: identity, health: health) } }
        }
        return children
    }

    private var sleepUnavailableReason: String? {
        switch live.status(of: .sleepAssertions) {
        case .unavailable(let r), .disabled(let r): r
        case .ok, .degraded: nil
        }
    }

    private func loadAverages(end: Date) async {
        let interval = DateInterval(start: end.addingTimeInterval(-12 * 3_600), end: end)
        guard let top = try? await history.topApps(.energy, in: interval, limit: 500) else { return }
        let map = Dictionary(top.map { ($0.identity.key, $0.average) }, uniquingKeysWith: max)
        if !Task.isCancelled, map != averages { averages = map }
    }

    private func columns(sleepReason: String?) -> [TTTable<EnergyRow>.Column] {
        let selected = selection
        return [
            .init(id: "name", title: "Process", width: .fraction(2, min: 0)) { row in
                AnyView(TTNameCell(identity: row.identity, name: row.name, disclosure: true))
            },
            .init(id: "energy", title: "Energy impact", width: .fixed(110), alignment: .trailing,
                  sortKey: { $0.watts }) { row in
                AnyView(MetricValue(row.watts == nil ? nil : TTFormat.appWatts(row.watts), unavailableReason: row.reason,
                                    estimated: row.estimated, font: TTFont.body12))
            },
            .init(id: "avg", title: "12 h average", width: .fixed(100), alignment: .trailing) { row in
                if row.isChild { return AnyView(Color.clear.frame(height: 1)) }
                return AnyView(MetricValue(row.average12h.map(TTFormat.appWatts),
                                           unavailableReason: row.average12h == nil ? "No history yet" : nil,
                                           font: TTFont.body12))
            },
            .init(id: "sleep", title: "Preventing sleep", width: .fixed(120)) { row in
                if let sleepReason { return AnyView(MetricValue(nil, unavailableReason: sleepReason, font: TTFont.body12)) }
                return AnyView(Text(row.preventsSleep ? "Yes" : "No")
                    .foregroundStyle(row.preventsSleep ? TTColor.statusElevated : TTColor.textSecondary))
            },
            // Selected user-owned row: [Quit] [Force Quit] leading; the shared self rule hides Force Quit for
            // Telltale and makes its Quit quit Telltale (`InlineActionsCell`, DESIGN §2.25).
            .init(id: "actions", title: "", width: .fixed(170), alignment: .trailing) { row in
                AnyView(InlineActionsCell(target: row.target, name: row.name, selected: selected == row.id))
            },
        ]
    }
}

