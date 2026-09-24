import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.10 Power & Battery: stat strip (6) · Power by component (span 2) + Battery · Energy impact (flex).
/// Energy values are average watts (§5.6); estimated rows carry an "Estimated" tooltip (ICR-8). No App Nap column.
public struct PowerPage: View {
    @Environment(LiveModel.self) private var live
    @State private var forceQuit: PowerPendingForceQuit?
    @State private var toast: String?

    private let initialSelection: String?

    public init() { initialSelection = nil }

    /// Tests/renders: start with an energy row selected (e.g. "app:app:com.apple.FinalCut").
    init(selectedRowID: String?) { initialSelection = selectedRowID }

    public var body: some View {
        PowerPageColumn {
            PowerStatStrip()
            PowerGrid3Row(minHeight: 285) {
                PowerByComponentCard()
                BatteryCard()
            }
            EnergyImpactCard(selection: initialSelection)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) {
            if let toast { PowerToast(text: toast).padding(.bottom, TTSpace.x20) }
        }
        .overlay {
            if let pending = forceQuit {
                PowerForceQuitDialog(pending: pending, onDone: { result in
                    forceQuit = nil
                    if let result { show(PowerCopy.toast(name: pending.name, forced: true, result: result)) }
                })
            }
        }
        .environment(\.requestForceQuit, { [binding = $forceQuit, live] target in
            binding.wrappedValue = PowerPendingForceQuit(target: target, name: PowerCopy.name(of: target, live: live))
        })
        .environment(\.onProcessActionResult, { [binding = $toast, live] target, result in
            let text = PowerCopy.toast(name: PowerCopy.name(of: target, live: live), forced: false, result: result)
            binding.wrappedValue = text
        })
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
        .pageHeader(subtitle: PowerCopy.subtitle(live.power))
    }

    private func show(_ text: String?) { toast = text }
}

// MARK: - Copy

enum PowerCopy {
    /// "On battery · 72.4 Wh · Low Power Mode off" / "On power adapter · 96 W · …" (DESIGN §3.10 header).
    static func subtitle(_ p: PowerSnapshot) -> String {
        var parts: [String] = []
        let onAC = p.battery?.onAC ?? true
        if onAC {
            parts.append(p.adapterWatts.map { "On power adapter · \(TTFormat.number($0, digits: 0)) W" } ?? "On power adapter")
        } else {
            parts.append("On battery")
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
    static func batteryPhrase(_ b: BatterySnapshot) -> String {
        if b.isCharging {
            return b.timeRemaining.map { "Charging · full in \(TTFormat.duration($0))" } ?? "Charging"
        }
        if b.onAC { return (b.percent ?? 0) >= 99.5 ? "Charged" : "On power adapter" }
        return b.timeRemaining.map { "On battery · about \(TTFormat.duration($0)) left" } ?? "On battery"
    }

    static func adapter(_ p: PowerSnapshot) -> String {
        guard p.battery?.onAC ?? true else { return "Not connected" }
        let watts = p.adapterWatts.map { "\(TTFormat.number($0, digits: 0)) W" }
        let parts = [watts, p.adapterName].compactMap { $0 }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " ")
    }

    /// Glyph fill: `battery`, `statusElevated` at ≤ 20 %, `statusCritical` at ≤ 10 % (ADDED).
    static func fillColor(percent: Double) -> Color {
        if percent <= 10 { return TTColor.statusCritical }
        if percent <= 20 { return TTColor.statusElevated }
        return TTColor.battery
    }

    @MainActor static func name(of target: ProcessTarget, live: LiveModel) -> String {
        switch target {
        case .app(let identity, _): identity.displayName
        case .process(_, let name, _, _): name
        }
    }

    static func toast(name: String, forced: Bool, result: ActionResult) -> String? {
        switch result {
        case .done: forced ? "\(name) was force quit." : "\(name) quit."
        case .notPermitted: "Not permitted to quit \(name)."
        case .failed(let message): "Couldn't quit \(name): \(message)"
        case .cancelled: nil
        }
    }
}

// MARK: - Layout helpers

private struct PowerPageColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.gridGap) { content }
            .padding(TTSpace.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTColor.bgWindow)
    }
}

/// `grid3` row of span 2 + 1, stretched to the tallest cell (at least `minHeight`).
private struct PowerGrid3Row: Layout {
    let minHeight: CGFloat

    static func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let col = max(0, total - 2 * TTSpace.gridGap) / 3
        return (2 * col + TTSpace.gridGap, col)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 1020
        let (a, b) = Self.widths(total)
        var h = minHeight
        for (i, s) in subviews.prefix(2).enumerated() {
            h = max(h, s.sizeThatFits(ProposedViewSize(width: i == 0 ? a : b, height: nil)).height)
        }
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = Self.widths(bounds.width)
        for (i, s) in subviews.prefix(2).enumerated() {
            s.place(at: CGPoint(x: i == 0 ? bounds.minX : bounds.minX + a + TTSpace.gridGap, y: bounds.minY),
                    anchor: .topLeading, proposal: ProposedViewSize(width: i == 0 ? a : b, height: bounds.height))
        }
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
                  unavailableReason: p.battery == nil ? "This Mac has no battery"
                      : (unavailableReason(.batteryPercent, health: h) ?? "Not reported by the battery")),
        ])
    }
}

// MARK: - Power by component

private struct PowerByComponentCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.now) private var fixedNow
    @Environment(\.historyProvider) private var history
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]

    private static let metrics: [HistoryMetric] = [.cpuWatts, .gpuWatts, .aneWatts, .dramWatts]

    var body: some View {
        let range = nav.range
        let end = fixedNow ?? live.lastUpdate ?? Date()
        let series = [
            ChartSeries(id: "cpu", label: "CPU", color: TTColor.cpu, points: points(.cpuWatts, range),
                        fillOpacity: TTChartFill.powerCPU),
            ChartSeries(id: "gpu", label: "GPU", color: TTColor.gpu, points: points(.gpuWatts, range),
                        fillOpacity: TTChartFill.powerGPU),
            ChartSeries(id: "ane", label: "ANE", color: TTColor.power, points: points(.aneWatts, range),
                        fillOpacity: TTChartFill.powerANE),
            ChartSeries(id: "dram", label: "DRAM", color: TTColor.dram, points: points(.dramWatts, range),
                        fillOpacity: TTChartFill.powerDRAM),
        ]
        let reason = unavailableReason(.cpuWatts, health: live.sensorHealth)
        let empty = series.allSatisfy { ChartSegments.sampleCount($0.points) < 2 }
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Power by component") { TTLegend(series) }
            Group {
                if let reason, empty {
                    TTEmptyState(.unavailable(reason))
                } else {
                    TTStackedArea(series, yDomain: 0...PowerChartScale.ceiling(series.map(\.points)))
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            TTTimeAxis(range: range, end: end)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: PowerRangeKey(range: range, end: end)) {
            guard range != .live else {
                if !stored.isEmpty { stored = [:] }
                return
            }
            let result = try? await history.series(Self.metrics, range: range, end: end, bucket: nil)
            if !Task.isCancelled { stored = result ?? [:] }
        }
    }

    private func points(_ metric: HistoryMetric, _ range: HistoryRange) -> [SeriesPoint] {
        range == .live ? live.series(metric) : (stored[metric] ?? [])
    }
}

enum PowerChartScale {
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

private struct PowerRangeKey: Hashable {
    let range: HistoryRange
    let slot: Int

    init(range: HistoryRange, end: Date) {
        self.range = range
        let bucket = Double(range.displayBucket.components.seconds)
        slot = range == .live ? 0 : Int(end.timeIntervalSince1970 / max(bucket, 1))
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
            if let b = p.battery {
                HStack(spacing: TTSpace.x14) {
                    BatteryGlyph(percent: b.percent)
                    VStack(alignment: .leading, spacing: 0) {
                        MetricValue(b.percent.map { TTFormat.percent($0 / 100) },
                                    unavailableReason: unavailableReason(.batteryPercent, health: live.sensorHealth),
                                    font: TTFont.title1)
                            .foregroundStyle(TTColor.textPrimary)
                        Text(PowerCopy.batteryPhrase(b)).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                TTKeyValueList(rows: [
                    .init("Health", b.healthFraction.map { "\(TTFormat.percent($0)) maximum capacity" },
                          unavailableReason: "Not reported by the battery"),
                    .init("Condition", b.condition, unavailableReason: "Not reported by the battery"),
                    .init("Cycle count", b.cycleCount.map { TTFormat.count($0) }, unavailableReason: "Not reported by the battery"),
                    .init("Capacity", Self.capacity(b), unavailableReason: "Not reported by the battery"),
                    .init("Temperature", b.temperatureC.map { TTFormat.temperature($0, units: units) },
                          unavailableReason: "Not reported by the battery"),
                    .init("Power adapter", PowerCopy.adapter(p)),
                ])
                Spacer(minLength: 0)
            } else {
                TTEmptyState(.empty("No battery")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

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
    /// App groups with energy > 0 or a sleep assertion (or an unavailable value to explain), excluding "Other".
    static func apps(_ apps: [AppSample], averages: [AppKey: Double], health: [SensorID: SensorStatus]) -> [EnergyRow] {
        apps.compactMap { a in
            guard a.identity.key != .other else { return nil }
            let reason = unavailableReason(.energy, a, health: health)
            guard (a.energyWatts ?? 0) > 0 || a.preventsSleep || reason != nil else { return nil }
            return EnergyRow(id: "app:\(a.identity.key)", name: a.identity.displayName, identity: a.identity,
                             watts: a.energyWatts, estimated: a.energyEstimated, reason: reason,
                             average12h: averages[a.identity.key], isChild: false, preventsSleep: a.preventsSleep,
                             target: .app(a.identity, pids: a.processIDs.map(\.pid)))
        }
    }

    static func process(_ p: ProcessSample, identity: AppIdentity?, health: [SensorID: SensorStatus]) -> EnergyRow {
        EnergyRow(id: "pid:\(p.id.pid):\(p.id.startTimeUs)", name: p.name, identity: nil, watts: p.energyWatts,
                  estimated: p.energyEstimated, reason: unavailableReason(.energy, p, health: health), average12h: nil,
                  isChild: true, preventsSleep: p.preventsSleep,
                  target: .process(pid: p.pid, name: p.name, path: p.path, uid: p.uid))
    }
}

private struct EnergyImpactCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var history
    @Environment(\.processActions) private var actions
    @Environment(\.now) private var fixedNow
    @State private var selection: String?
    @State private var averages: [AppKey: Double] = [:]

    init(selection: String? = nil) { _selection = State(initialValue: selection) }

    var body: some View {
        let health = live.sensorHealth
        let rows = EnergyRows.apps(live.apps, averages: averages, health: health)
        let children = childMap(rows, health: health)
        let sleepReason = sleepUnavailableReason
        let end = fixedNow ?? live.lastUpdate ?? Date()
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Energy impact") {
                TTLink("All processes") {
                    nav.processesMode = .apps
                    nav.page = .processes
                }
            }
            TTTable(rows: rows, columns: columns(sleepReason: sleepReason), selection: $selection,
                    sort: .constant((column: "energy", descending: true)),
                    rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                    children: { children[$0.id] ?? [] },
                    style: TTTableStyle(emptyMessage: "No app energy use"))
                .clipped()
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
        let actions = actions
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
            .init(id: "actions", title: "", width: .fixed(170), alignment: .trailing) { row in
                if selected == row.id, actions.canControl(row.target) {
                    return AnyView(EnergyInlineActions(row: row).frame(maxWidth: .infinity, alignment: .leading))
                }
                return AnyView(RowActionsImageButton(target: row.target, name: row.name))
            },
        ]
    }
}

/// Selected user-owned row: [Quit (small secondary)] [Force Quit (small destructive)], leading-aligned.
private struct EnergyInlineActions: View {
    let row: EnergyRow
    @Environment(\.processActions) private var actions
    @Environment(\.requestForceQuit) private var requestForceQuit
    @Environment(\.onProcessActionResult) private var onResult

    var body: some View {
        HStack(spacing: TTSpace.x6) {
            Button("Quit") {
                let target = row.target, actions = actions, onResult = onResult
                Task { @MainActor in
                    let result = await actions.quit(target)
                    onResult?(target, result)
                }
            }
            .buttonStyle(.tt(.smallSecondary))
            Button("Force Quit") { requestForceQuit?(row.target) }
                .buttonStyle(.tt(.smallDestructive))
        }
    }
}

// TODO(W3): replace with TTRowActionsButton once its Menu label draws (macOS Menu labels drop Shape-based views,
// so its TTIcon "…" renders empty). Same look: 24-pt `rowAction`, radius 5, `ellipsis` 16 `textSecondary`.
/// Shared by the Power and Disk tables.
struct RowActionsImageButton: View {
    let target: ProcessTarget
    let name: String
    @State private var hovering = false

    /// The `ellipsis` icon rasterized once (Menu labels accept images and text only).
    @MainActor static let ellipsis: NSImage = {
        let renderer = ImageRenderer(content: TTIcon(.ellipsis, size: 16, color: TTColor.textSecondary)
            .frame(width: 16, height: 16))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 16))
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    var body: some View {
        Menu {
            TTRowActionsMenu(target: target)
        } label: {
            Image(nsImage: Self.ellipsis)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: TTRadius.r5, style: .continuous)
            .fill(hovering ? TTColor.fillIconButton : .clear))
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Actions for \(name)")
        .accessibilityLabel("Actions for \(name)")
    }
}

// MARK: - Force quit confirm + toast (placeholders)

struct PowerPendingForceQuit: Identifiable, Equatable {
    var target: ProcessTarget
    var name: String
    var id: ProcessTarget { target }
}

// TODO(W3 T12): replace with TTConfirmDialog once it renders (the W0b stub draws nothing).
/// DESIGN §2.26 over the page area: scrim, 380-wide `bgElevated` dialog 52 below the top, [Cancel] [Force Quit].
private struct PowerForceQuitDialog: View {
    let pending: PowerPendingForceQuit
    let onDone: (ActionResult?) -> Void
    @Environment(\.processActions) private var actions

    var body: some View {
        ZStack(alignment: .top) {
            TTColor.bgScrim.onTapGesture { onDone(nil) }
            VStack(alignment: .leading, spacing: TTSpace.x12) {
                Text("Force quit “\(pending.name)”?").font(TTFont.dialogTitle).foregroundStyle(TTColor.textPrimary)
                Text("Unsaved changes will be lost. The process ends immediately without cleanup.")
                    .font(TTFont.body12Para).foregroundStyle(TTColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: TTSpace.x8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { onDone(nil) }
                        .buttonStyle(.tt(.regularSecondary))
                        .keyboardShortcut(.cancelAction)
                    Button("Force Quit") {
                        let target = pending.target, actions = actions
                        Task { @MainActor in onDone(await actions.forceQuit(target)) }
                    }
                    .buttonStyle(.tt(.regularDestructive))
                }
                .padding(.top, TTSpace.x4)
            }
            .padding(TTSpace.x20)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: TTRadius.window, style: .continuous).fill(TTColor.bgElevated)
                .strokeBorder(TTColor.borderPopover, lineWidth: TTStroke.hairline))
            .shadow(color: .black.opacity(0.55), radius: 30, y: 24)
            .padding(.top, 52)
        }
    }
}

// TODO(W3 T12): replace with TTToast once it renders.
private struct PowerToast: View {
    let text: String

    var body: some View {
        Text(text).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
            .padding(.horizontal, TTSpace.x12).frame(height: 28)
            .background(Capsule().fill(TTColor.bgElevated).strokeBorder(TTColor.borderPopover, lineWidth: TTStroke.hairline))
    }
}
