import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.4 Overview (Main). Content 1020 × 768 at the default size:
/// tiles `grid5` (168) · `grid3` row (min 276): "Last 60 seconds" span 2 | Power (min 134) over Disk (min 120, flex)
/// · Top processes (flex). The header subtitle comes from the shell (`PageHeader.defaultSubtitle`).
/// Each block is its own view, so a tick re-evaluates only the blocks that read the changed category; the page root
/// reads no live state (the range readers sit inside the tiles and the timeline card), so a Live tick never
/// re-lays out the page container (U-M1).
public struct OverviewPage: View {
    public init() {}

    public var body: some View {
        FlexPage(minContentHeight: 168 + 276 + 200 + 2 * TTSpace.gridGap) {
            OverviewTiles()
            GridRow(columns: 3, spans: [2, 1], minHeight: 276) {
                OverviewTimelineCard()
                VStack(spacing: TTSpace.gridGap) {
                    OverviewPowerCard()
                    OverviewDiskCard()
                }
            }
            OverviewTopProcessesCard()
                .frame(minHeight: 200, maxHeight: .infinity, alignment: .top)
        }
        .processActionsHost()
    }
}

// MARK: - Tiles

/// DESIGN §3.4.1: five `TTMetricTile`s (`grid5`); click navigates to the category page.
struct OverviewTiles: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.unitPreferences) private var units
    @State private var ceilings = LiveCeilings()

    /// Same five metrics as the timeline card (each card reads the store once per bucket in stored ranges).
    static let metrics: [HistoryMetric] = [.cpuUsage, .gpuUsage, .memUsed, .netRx, .socTemp]

    var body: some View {
        RangeSeriesReader(Self.metrics) { series in
            GridRow(columns: 5) {
                ForEach(Self.tiles(series, live: live, units: units, ceilings: ceilings), id: \.category) { t in
                    TTMetricTile(category: t.category, value: t.value, prefix: t.prefix, unit: t.unit, detail: t.detail,
                                 points: t.points, unavailableReason: t.reason, yDomain: t.domain,
                                 showsCollecting: !t.sensorDown, partialHistory: series.range != .live) {
                        nav.page = t.category.dashboardPage
                    }
                    .equatable()
                }
            }
        }
    }

    struct Tile {
        var category: MonitorModel.Category
        var value: String?
        var prefix: String?
        var unit: String?
        var detail: String?
        var points: [SeriesPoint]
        var domain: ClosedRange<Double>?
        var reason: String?
        /// The sources are down (reason from sensor health): "—" + an empty chart instead of "Collecting…".
        var sensorDown = false
    }

    static func tiles(_ s: RangeSeries, live: LiveModel, units: UnitPreferences,
                      ceilings: LiveCeilings = LiveCeilings()) -> [Tile] {
        // M3: every "—" gets a reason — the sensor's, or a fallback while the sensor is fine.
        base(s, live: live, units: units, ceilings: ceilings).map { t in
            var t = t
            (t.reason, t.sensorDown) = headlineReason(t.category.headlineMetric, value: t.value, live: live)
            return t
        }
    }

    private static func base(_ s: RangeSeries, live: LiveModel, units: UnitPreferences,
                             ceilings: LiveCeilings) -> [Tile] {

        let cpu = splitUnit(TTFormat.percent(live.cpu.usage))
        let p = live.cpu.clusters.first { $0.kind == .performance }?.frequencyMHz
        let e = live.cpu.clusters.first { $0.kind == .efficiency }?.frequencyMHz
        let cpuSub = [p.map { "P " + TTFormat.ghz($0) }, e.map { "E " + TTFormat.ghz($0) }].compactMap { $0 }

        let gpu = splitUnit(TTFormat.percent(live.gpu.usage))
        let gpuSub = [live.gpu.frequencyMHz.map { TTFormat.frequency($0) },
                      live.gpu.allocatedMemory.map { TTFormat.memory($0, style: .headline) }].compactMap { $0 }

        let mem = splitUnit(TTFormat.memory(live.memory.used, style: .headline))
        var memSub: [String] = []
        if live.memory.total > 0 { memSub.append("of " + TTFormat.memory(live.memory.total, style: .total)) }
        if let level = live.memory.pressureLevel { memSub.append("pressure " + level.title.lowercased()) }

        let net = live.network
        var netSub: [String] = []
        if let tx = net.txBps { netSub.append(TTFormat.rate(tx, units: units, direction: .up)) }
        if let primary = net.interfaces.first(where: \.isPrimary) { netSub.append(Self.interfaceType(primary)) }

        let temp = splitUnit(TTFormat.temperature(live.thermals.socAverage, units: units))
        var thermSub = ["SoC avg"]
        if live.device.fanCount == 0 {
            thermSub.append("no fans")
        } else if let rpm = W5a.averageFanRPM(live.thermals.fans) {
            thermSub.append("fans " + TTFormat.rpm(rpm))
        }

        return [
            Tile(category: .cpu, value: cpu.value, unit: cpu.unit, detail: cpuSub.joined(separator: " · "),
                 points: s[.cpuUsage], domain: 0...1),
            Tile(category: .gpu, value: gpu.value, unit: gpu.unit, detail: gpuSub.joined(separator: " · "),
                 points: s[.gpuUsage], domain: 0...1),
            Tile(category: .memory, value: mem.value, unit: mem.unit, detail: memSub.joined(separator: " · "),
                 points: s[.memUsed], domain: 0...Double(max(live.memory.total, 1))),
            Tile(category: .network, value: net.rxBps.map { TTFormat.rate($0, units: units) }, prefix: "↓ ", unit: nil,
                 detail: netSub.joined(separator: " · "), points: s[.netRx],
                 domain: ceilings.domain("netRx", range: s.range, W5a.rateDomain(s[.netRx]))),
            Tile(category: .thermals, value: temp.value, unit: temp.unit, detail: thermSub.joined(separator: " · "),
                 points: s[.socTemp], domain: 0...100),
        ]
    }

    /// Primary interface type: Wi-Fi / Ethernet / Thunderbolt Bridge / USB (else its display name).
    static func interfaceType(_ i: InterfaceSnapshot) -> String {
        switch i.kind {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .thunderbolt: "Thunderbolt Bridge"
        case .cellular, .other: i.displayName
        }
    }
}

// MARK: - Last 60 seconds

/// DESIGN §3.4.2: card gap 12, min 276: header (range title + "Open History"), 5 × `TTTimelineRow` (gap 4), axis
/// inset 96; extra height goes below the axis.
struct OverviewTimelineCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units
    @State private var ceilings = LiveCeilings()

    var body: some View {
        RangeSeriesReader(OverviewTiles.metrics) { s in card(s) }
    }

    private func card(_ s: RangeSeries) -> some View {
        TTCard(spacing: TTSpace.gridGap) {
            TTCardHeader(s.range.lastTitle) { PageLink("Open History", to: .history) }
            VStack(spacing: TTSpace.x4) {
                ForEach(rows(s), id: \.label) { r in
                    // M3: a "—" always has a reason; only a down sensor turns "Collecting…" off.
                    let h = headlineReason(r.metric, value: r.value, live: live)
                    TTTimelineRow(label: r.label, icon: nil, value: r.value, unavailableReason: h.reason,
                                  points: r.points, color: r.color, yDomain: r.domain, showsCollecting: !h.sensorDown,
                                  partialHistory: s.range != .live)
                        .equatable()
                }
            }
            TTTimeAxis(range: s.range, end: s.end)
                .frame(width: 480)
                .padding(.leading, 96)
                .fillBelow()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    struct Row {
        var label: String
        var value: String?
        /// Headline metric (its sensor health gives the "—" reason).
        var metric: HistoryMetric
        var points: [SeriesPoint]
        var color: Color
        var domain: ClosedRange<Double>
    }

    func rows(_ s: RangeSeries) -> [Row] {
        [
            Row(label: "CPU", value: TTFormat.percent(live.cpu.usage), metric: .cpuUsage,
                points: s[.cpuUsage], color: TTColor.cpu, domain: 0...1),
            Row(label: "GPU", value: TTFormat.percent(live.gpu.usage), metric: .gpuUsage,
                points: s[.gpuUsage], color: TTColor.gpu, domain: 0...1),
            Row(label: "Memory", value: TTFormat.memory(live.memory.used, style: .headline), metric: .memUsed,
                points: s[.memUsed], color: TTColor.mem, domain: 0...Double(max(live.memory.total, 1))),
            Row(label: "Network", value: TTFormat.rate(live.network.rxBps, units: units), metric: .netRx,
                points: s[.netRx], color: TTColor.net,
                domain: ceilings.domain("netRx", range: s.range, W5a.rateDomain(s[.netRx]))),
            Row(label: "Thermals", value: TTFormat.temperature(live.thermals.socAverage, units: units),
                metric: .socTemp, points: s[.socTemp], color: TTColor.thermal, domain: 0...100),
        ]
    }
}

// MARK: - Power

/// DESIGN §3.4.3: gap 10, min 134: header (power icon, "Power", "Details"); "18.6 W package" | battery phrase;
/// split bar (CPU/GPU/ANE/DRAM of package + `fillRest`); legend with values.
struct OverviewPowerCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let p = live.power
        let reason = unavailableReason(.packageWatts, health: live.sensorHealth)
        let package = splitUnit(TTFormat.watts(W5a.packageWatts(p)))
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Power", icon: "power") { PageLink("Details", to: .power) }
            HStack(alignment: .lastTextBaseline) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    MetricValue(package.value, unavailableReason: reason, font: TTFont.title1)
                        .foregroundStyle(TTColor.textPrimary)
                    Text(package.value == nil ? " package" : " W package")
                        .font(TTFont.title1Unit).foregroundStyle(TTColor.textSecondary)
                }
                Spacer(minLength: 8)
                if let phrase = PopoverModel.powerPhrase(p, device: live.device, lastUpdate: live.lastUpdate) {
                    HStack(spacing: 6) {
                        if p.battery != nil { TTIcon(.battery, size: 16) }
                        Text(phrase).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).monospacedDigit()
                    }
                    .lineLimit(1)
                }
            }
            TTSegmentBar(segments(p), style: .split, remainder: TTColor.fillRest)
            ColumnLegend(items: [
                legendItem("CPU", p.cpuWatts, .cpuWatts, TTColor.cpu),
                legendItem("GPU", p.gpuWatts, .gpuWatts, TTColor.gpu),
                legendItem("ANE", p.aneWatts, .aneWatts, TTColor.power),
                legendItem("DRAM", p.dramWatts, .dramWatts, TTColor.dram),
            ])
        }
        .frame(minHeight: 134, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)   // Disk below takes the column's extra height
    }

    /// "CPU 11.0 W"; a missing value is "CPU —" with the reason (M3).
    private func legendItem(_ label: String, _ watts: Double?, _ metric: HistoryMetric, _ color: Color) -> ColumnLegend.Item {
        let value = watts.map { TTFormat.watts($0) }
        return .init(label: label, value: value,
                     reason: headlineReason(metric, value: value, live: live).reason, color: color)
    }

    private func segments(_ p: PowerSnapshot) -> [TTSegmentBar.Segment] {
        guard let total = W5a.packageWatts(p), total > 0 else { return [] }
        return [(p.cpuWatts, TTColor.cpu), (p.gpuWatts, TTColor.gpu), (p.aneWatts, TTColor.power),
                (p.dramWatts, TTColor.dram)]
            .map { TTSegmentBar.Segment(($0.0 ?? 0) / total, $0.1) }
    }
}

// MARK: - Disk

/// DESIGN §3.4.4: gap 10, min 120, flexes to fill the column (extra below the stats line): header; volume name |
/// "612 of 994 GB used"; medium used bar in `disk`; "Read … · Write … · … free" (gap 16).
struct OverviewDiskCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let d = live.disk
        let v = d.bootVolume
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Disk", icon: "disk") { PageLink("Details", to: .disk) }
            HStack {
                Text(v?.name ?? "Boot volume").foregroundStyle(TTColor.textPrimary)
                Spacer(minLength: 8)
                MetricValue(v.map(Self.usedPhrase), unavailableReason: "Boot volume not reported", font: TTFont.body12)
                    .foregroundStyle(TTColor.textSecondary)
            }
            .font(TTFont.body12).lineLimit(1)
            TTProgressBar(value: v.map(Self.usedFraction), tint: TTColor.disk, style: .medium)
                .accessibilityLabel("Boot volume used")   // M13: not a bare "Progress"
            HStack(spacing: 16) {
                labeled("Read", d.readBps, .diskRead)
                labeled("Write", d.writeBps, .diskWrite)
                if let v { Text(ShellFormat.freeSpace(v) + " free") }   // one owner of the free-space rule (W4)
            }
            .font(TTFont.body12).foregroundStyle(TTColor.textSecondary).monospacedDigit().lineLimit(1)
            .fillBelow()
        }
        .frame(minHeight: 120, maxHeight: .infinity, alignment: .top)
    }

    /// "Read 207 MB/s"; a missing rate is "Read —" (`textTertiary`) with the reason (M3).
    private func labeled(_ label: String, _ bps: Double?, _ metric: HistoryMetric) -> some View {
        let value = bps.map { TTFormat.diskRate($0) }
        return LabeledMetricText(label: label, value: value,
                                 reason: headlineReason(metric, value: value, live: live).reason, font: TTFont.body12)
    }

    static func usedFraction(_ v: VolumeInfo) -> Double {
        v.totalBytes > 0 ? Double(v.totalBytes - min(W5a.freeBytes(v), v.totalBytes)) / Double(v.totalBytes) : 0
    }

    /// "612 of 994 GB used" (capacity style; the unit shown once when both share it).
    static func usedPhrase(_ v: VolumeInfo) -> String {
        let used = splitUnit(TTFormat.storage(v.totalBytes - min(W5a.freeBytes(v), v.totalBytes), style: .capacity))
        let total = TTFormat.storage(v.totalBytes, style: .capacity)
        let t = splitUnit(total)
        if used.unit == t.unit, let u = used.value { return "\(u) of \(total) used" }
        return "\(used.value ?? "—") \(used.unit ?? "") of \(total) used"
    }
}

// MARK: - Top processes

/// DESIGN §3.4.5: gap 8, flex; app groups sorted by CPU; template `minmax(0,2.2fr) 1fr×5 28`; energy in W (§5.6).
struct OverviewTopProcessesCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.unitPreferences) private var units
    @State private var selection: AppKey?
    @State private var sort: (column: String, descending: Bool) = ("cpu", true)
    @State private var cache = RankCache<AppSample>()

    var body: some View {
        let health = live.sensorHealth
        // Ranked once per apps change (`appsVersion`), not on every body evaluation (U-M1).
        let rows = cache.rows(version: live.appsVersion) { Self.rows(live) }
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Top processes") { PageLink("All processes", to: .processes) }
            FitRows { n in   // "as many as fit (≈4 at the default size)"
                TTTable(rows: Array(rows.prefix(n)), columns: columns(health), selection: $selection, sort: $sort,
                        rowMenu: { a in
                            a.isExitedResidualOnly ? AnyView(EmptyView()) : AnyView(TTRowActionsMenu(target: a.target))
                        }, children: nil,
                        // Pre-sorted by CPU before the prefix; the table must not re-sort (header sorting is off).
                        style: TTTableStyle(sortsRows: false, scrolls: false, emptyMessage: "No processes"),
                        onDoubleClick: open, columnsVersion: tableColumnsVersion(live, units: units))
            }
        }
    }

    /// App groups by CPU, descending — sorted here, before the "as many as fit" prefix.
    static func rows(_ live: LiveModel) -> [AppSample] {
        live.apps.filter { $0.identity.key != .other }
            .sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
    }

    private func open(_ app: AppSample) {
        nav.selection = .app(app.identity.key)
        nav.page = .processes
    }

    private func columns(_ health: [SensorID: SensorStatus]) -> [TTTable<AppSample>.Column] {
        let units = units
        let live = live
        return [
            .init(id: "name", title: "Process", width: .fraction(2.2, min: 0)) { a in
                a.isExitedResidualOnly ? AnyView(ExitedNameCell(identity: a.identity, name: a.name))
                    : AnyView(AppNameCell(app: a))
            },
            .init(id: "cpu", title: "CPU", width: .fraction(1, min: 0), alignment: .trailing, sortKey: \.cpuPercent) {
                metricCell(TTFormat.cpuPercent($0.cpuPercent), reason: unavailableReason(.cpu, $0, health: health),
                           estimated: $0.cpuIsEstimated(live))
            },
            .init(id: "gpu", title: "GPU", width: .fraction(1, min: 0), alignment: .trailing) {
                metricCell(TTFormat.cpuPercent($0.gpuPercent), reason: unavailableReason(.gpu, $0, health: health))
            },
            .init(id: "memory", title: "Memory", width: .fraction(1, min: 0), alignment: .trailing) {
                metricCell(TTFormat.memory($0.memory, style: .detail), reason: unavailableReason(.memory, $0, health: health))
            },
            .init(id: "network", title: "Network", width: .fraction(1, min: 0), alignment: .trailing) { a in
                let total: Double? = a.netRxBps == nil && a.netTxBps == nil ? nil : (a.netRxBps ?? 0) + (a.netTxBps ?? 0)
                return metricCell(TTFormat.rateCell(total, units: units), reason: unavailableReason(.netRx, a, health: health))
            },
            .init(id: "energy", title: "Energy impact", width: .fraction(1, min: 0), alignment: .trailing) {
                metricCell(TTFormat.appWatts($0.energyWatts), reason: unavailableReason(.energy, $0, health: health),
                           estimated: $0.energyIsEstimated)
            },
            .init(id: "actions", title: "", width: .fixed(28), alignment: .trailing) { a in
                a.isExitedResidualOnly ? AnyView(EmptyView()) : AnyView(TTRowActionsButton(target: a.target, name: a.name))
            },
        ]
    }
}
