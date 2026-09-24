import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.5 CPU. Stat strip (6, ≈82) · cores `grid3` (P span 2 | E, min 236) · Usage (min 196) · Top CPU
/// consumers (flex, rows scroll). Subtitle "{chip} · {n} cores ({p} performance + {e} efficiency)" is the shell
/// default (`PageHeader.defaultSubtitle`).
public struct CPUPage: View {
    private let initialSelection: ProcessID?

    public init() { initialSelection = nil }

    /// Snapshot hook: a pre-selected row shows the inline [Quit][Force Quit] (DESIGN §2.20).
    init(selection: ProcessID?) { initialSelection = selection }

    public var body: some View {
        FlexPage(minContentHeight: 82 + 236 + 196 + 130 + 3 * TTSpace.gridGap) {
            CPUStatStrip()
            GridRow(columns: 3, spans: [2, 1], minHeight: 236) {
                CPUClusterCard(kind: .performance)
                CPUClusterCard(kind: .efficiency)
            }
            CPUUsageCard()
            CPUConsumersCard(selection: initialSelection)
                .frame(minHeight: 130, maxHeight: .infinity, alignment: .top)
        }
        .processActionsHost()
    }
}

// MARK: - Stat strip

struct CPUStatStrip: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        TTStatStrip(Self.items(live))
    }

    static func items(_ live: LiveModel) -> [TTStatStrip.Item] {
        let c = live.cpu
        let reason = unavailableReason(.cpuUsage, health: live.sensorHealth)
        let cores = live.device.performanceCores + live.device.efficiencyCores
        let loadReason = unavailableReason(.loadAvg1, health: live.sensorHealth)
        return [
            .init(id: "total", label: "Total", value: TTFormat.percent(c.usage),
                  detail: cores > 0 ? "of \(TTFormat.count(cores)) cores" : nil, tint: TTColor.cpu, unavailableReason: reason),
            .init(id: "user", label: "User", value: TTFormat.percent(c.user, digits: 1), unavailableReason: reason),
            .init(id: "system", label: "System", value: TTFormat.percent(c.system, digits: 1), unavailableReason: reason),
            .init(id: "idle", label: "Idle", value: TTFormat.percent(c.idle, digits: 1), unavailableReason: reason),
            .init(id: "load", label: "Load average", value: W5a.loadAverage(c.loadAverage), detail: "1 · 5 · 15 min",
                  unavailableReason: loadReason ?? "Not reported"),
            .init(id: "threads", label: "Threads", value: TTFormat.count(c.threadCount),
                  detail: c.processCount.map { "in \(TTFormat.count($0)) processes" },
                  unavailableReason: "Not reported by the process table"),
        ]
    }
}

// MARK: - Cluster cards

/// DESIGN §3.5.2–3: gap 12, min 236: header + badge "{n} cores" (P `cpu` / E `cpuAlt` dot); `TTCoreBars`; footer
/// (gap 18, `caption` `textSecondary`) "{f} of {max}", "Active residency {r}", P only: "Cluster power {W}" ("—" if
/// absent). Extra height goes below the footer.
struct CPUClusterCard: View {
    let kind: ClusterKind
    @Environment(LiveModel.self) private var live

    private var isP: Bool { kind == .performance }
    private var color: Color { isP ? TTColor.cpu : TTColor.cpuAlt }

    var body: some View {
        let cluster = live.cpu.clusters.first { $0.kind == kind }
        let coreKind: CoreKind = isP ? .performance : .efficiency
        let cores = live.cpu.cores.filter { $0.kind == coreKind }
        let count = cluster?.coreCount ?? (isP ? live.device.performanceCores : live.device.efficiencyCores)
        let reasons = Self.reasons(clusters: live.cpu.clusters, health: live.sensorHealth)
        TTCard(spacing: TTSpace.gridGap) {
            TTCardHeader(isP ? "Performance cores" : "Efficiency cores") {
                TTBadge("\(TTFormat.count(count)) cores", dot: color)
            }
            if cores.isEmpty {
                TTEmptyState(.collecting(since: nil)).frame(height: 143)
            } else {
                TTCoreBars(cores: cores, kind: coreKind, color: color)
            }
            HStack(spacing: 18) {
                MetricValue(Self.frequency(cluster), unavailableReason: reasons.frequency, font: TTFont.caption)
                HStack(spacing: 0) {
                    Text("Active residency ")
                    MetricValue(TTFormat.percent(cluster?.activeResidency), unavailableReason: reasons.ioReport,
                                font: TTFont.caption)
                }
                if isP {   // the E footer (298 wide) has room for two items only (DESIGN §3.5.3)
                    HStack(spacing: 0) {
                        Text("Cluster power ")
                        MetricValue(TTFormat.watts(cluster?.watts), unavailableReason: reasons.ioReport,
                                    font: TTFont.caption)
                    }
                }
            }
            .font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
            .fillBelow()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Footer tooltips: IOReport fields take the SoC sensor's own reason (fallback "Not reported by IOReport");
    /// frequency has none while collecting (no clusters yet), else "Not reported".
    static func reasons(clusters: [ClusterSnapshot], health: [SensorID: SensorStatus])
        -> (frequency: String?, ioReport: String) {
        let soc: String? = switch health[.soc] {
        case .unavailable(let r)?, .disabled(let r)?: r
        default: nil
        }
        return (clusters.isEmpty ? nil : (soc ?? "Not reported"), soc ?? "Not reported by IOReport")
    }

    /// "4.12 GHz of 4.51 GHz"; the maximum is dropped when unknown; nil → "—".
    static func frequency(_ c: ClusterSnapshot?) -> String? {
        guard let f = c?.frequencyMHz else { return nil }
        guard let m = c?.maxFrequencyMHz else { return TTFormat.ghz(f) }
        return "\(TTFormat.ghz(f)) of \(TTFormat.ghz(m))"
    }
}

// MARK: - Usage

/// DESIGN §3.5.4: gap 10, min 196: header "Usage" + legend [User `cpu`][System `cpuAlt`]; `TTStackedArea`
/// (user `cpu` @ 0.55 under user+system `cpuAlt` @ 0.35, outline `cpuLine` 1.25 @ 0.9; flex, min 110); axis.
struct CPUUsageCard: View {
    var body: some View {
        RangeSeriesReader([.cpuUser, .cpuSystem]) { s in
            let user = ChartSeries(id: "user", label: "User", color: TTColor.cpu, points: s[.cpuUser],
                                   fillOpacity: TTChartFill.cpuUser)
            let system = ChartSeries(id: "system", label: "System", color: TTColor.cpuAlt, points: s[.cpuSystem],
                                     fillOpacity: TTChartFill.cpuSystem)
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Usage") { TTLegend([user, system]) }
                TTStackedArea([user, system], yDomain: 0...1, outline: TTColor.cpuLine.opacity(TTChartFill.cpuOutline))
                    .equatable()
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .accessibilityLabel(ChartAccessibility.summary([user, system]))
                TTTimeAxis(range: s.range, end: s.end)
            }
            .frame(minHeight: 196)
            .fixedSize(horizontal: false, vertical: true)   // the consumers table takes the page's extra height
        }
    }
}

// MARK: - Top CPU consumers

/// DESIGN §3.5.5: gap 8; individual processes by % CPU; template `minmax(0,2fr) 70 110 80 90 70 170`;
/// a selected controllable row shows inline [Quit][Force Quit]. Rows beyond the card scroll (snapshots: whole
/// rows that fit).
struct CPUConsumersCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var selection: ProcessID?
    @State private var sort: (column: String, descending: Bool) = ("cpu", true)
    @State private var cache = RankCache<ProcessSample>()

    init(selection: ProcessID?) { _selection = State(initialValue: selection) }

    nonisolated static let cap = 50

    /// Top 50 by % CPU, descending, nil last, stable — sorted before the cap (the table does not re-sort).
    nonisolated static func rank(_ processes: [ProcessSample]) -> [ProcessSample] {
        Array(TTSort.stable(processes) { $0.cpuPercent }.prefix(cap))
    }

    static func rows(_ live: LiveModel) -> [ProcessSample] { rank(live.processes) }

    var body: some View {
        let rows = cache.rows(version: live.appsVersion) { Self.rank(live.processes) }
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Top CPU consumers") { PageLink("All processes", to: .processes) }
            FitRows { n in
                TTTable(rows: isSnapshot ? Array(rows.prefix(n)) : rows, columns: columns(), selection: $selection,
                        sort: $sort, rowMenu: { p in
                            p.isExitedResidualRow ? AnyView(EmptyView()) : AnyView(TTRowActionsMenu(target: p.target))
                        }, children: nil,
                        style: TTTableStyle(sortsRows: false, emptyMessage: "No processes"), onDoubleClick: open,
                        columnsVersion: tableColumnsVersion(live))   // cells capture health (M2)
            }
        }
    }

    private func open(_ p: ProcessSample) {
        nav.processesMode = .processes
        nav.selection = .process(p.id)
        nav.page = .processes
    }

    private func columns() -> [TTTable<ProcessSample>.Column] {
        let health = live.sensorHealth
        let selected = selection
        let live = live
        return [
            .init(id: "name", title: "Process", width: .fraction(2, min: 0)) { p in
                p.isExitedResidualRow
                    ? AnyView(ExitedNameCell(identity: live.app(p.app)?.identity, name: p.name))
                    : AnyView(TTNameCell(identity: live.app(p.app)?.identity, name: p.name))
            },
            .init(id: "pid", title: "PID", width: .fixed(70), alignment: .trailing) { p in
                AnyView(Text(p.isExitedResidualRow ? "" : String(p.pid)))   // ICR-13: no PID
            },
            .init(id: "user", title: "User", width: .fixed(110)) {
                AnyView(MetricValue($0.user, unavailableReason: "Owner not reported", font: TTFont.body12)
                    .foregroundStyle(TTColor.textSecondary).truncationMode(.tail))
            },
            .init(id: "cpu", title: "% CPU", width: .fixed(80), alignment: .trailing, sortKey: \.cpuPercent) {
                metricCell(TTFormat.cpuPercent($0.cpuPercent, sign: false), reason: unavailableReason(.cpu, $0, health: health),
                           estimated: $0.provenance == .coalition)
            },
            .init(id: "time", title: "CPU time", width: .fixed(90), alignment: .trailing) {
                metricCell(TTFormat.cpuTime($0.cpuTimeNs), reason: $0.cpuTimeNs == nil ? "Not available for this process" : nil)
            },
            .init(id: "threads", title: "Threads", width: .fixed(70), alignment: .trailing) {
                metricCell($0.threads.map { TTFormat.count(Int($0)) },
                           reason: $0.threads == nil ? "Not available for this process" : nil)
            },
            .init(id: "actions", title: "", width: .fixed(170)) { p in
                AnyView(InlineActionsCell(target: p.target, name: p.name, selected: selected == p.id,
                                          exited: p.isExitedResidualRow))
            },
        ]
    }
}
