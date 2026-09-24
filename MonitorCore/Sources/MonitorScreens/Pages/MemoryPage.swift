import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.7 Memory. Stat strip (5) · Composition (≈131) · `grid3` (Memory pressure span 2 | Swap; 240) · Top memory
/// consumers (flex). Subtitle "24 GB unified memory · LPDDR5X · 273 GB/s" is the shell default.
/// Ruling: the table is Process | Memory | … (no Compressed/Private/Ports).
public struct MemoryPage: View {
    public init() {}

    public var body: some View {
        FlexPage(minContentHeight: 82 + 131 + 240 + 130 + 3 * TTSpace.gridGap) {
            MemoryStatStrip()
            MemoryCompositionCard()
            GridRow(columns: 3, spans: [2, 1], minHeight: 240) {
                MemoryPressureCard()
                MemorySwapCard()
            }
            MemoryConsumersCard()
                .frame(minHeight: 130, maxHeight: .infinity, alignment: .top)
        }
        .forceQuitHost()
    }
}

// MARK: - Stat strip

struct MemoryStatStrip: View {
    @Environment(LiveModel.self) private var live

    var body: some View { TTStatStrip(Self.items(live)) }

    static func items(_ live: LiveModel) -> [TTStatStrip.Item] {
        let m = live.memory
        let reason = unavailableReason(.memUsed, health: live.sensorHealth)
        let pages: String? = m.pageInsPerSec.flatMap { i in
            m.pageOutsPerSec.map { o in TTFormat.number(i) + " · " + TTFormat.number(o) }
        }
        return [
            .init(id: "used", label: "Used", value: TTFormat.memory(m.used, style: .headline),
                  detail: m.total > 0 ? "of " + TTFormat.memory(m.total, style: .total) : nil, tint: TTColor.mem,
                  unavailableReason: reason),
            // TODO(W3): the level word is colored (Warning amber, Critical red); TTStatStrip has no detail tint yet.
            .init(id: "pressure", label: "Memory pressure", value: TTFormat.percent(m.pressureFraction),
                  detail: m.pressureLevel?.title, unavailableReason: reason),
            .init(id: "swap", label: "Swap used", value: TTFormat.memory(m.swapUsed, style: .swap),
                  detail: m.swapTotal.map { "of \(TTFormat.memory($0, style: .swap)) allocated" },
                  unavailableReason: reason ?? "Not reported by vm.swapusage"),
            .init(id: "compressed", label: "Compressed", value: TTFormat.memory(m.compressed, style: .headline),
                  detail: m.compressionRatio.map { "ratio " + TTFormat.compressionRatio($0) }, unavailableReason: reason),
            .init(id: "pages", label: "Page-ins · outs", value: pages, detail: "per second",
                  unavailableReason: reason ?? "Not reported"),
        ]
    }
}

// MARK: - Composition

/// DESIGN §3.7.2: gap 12: header + caption "24.0 GB unified memory"; composition bar (App `mem`, Wired `memWired`,
/// Compressed `memCompressed`, Cached `memCached`, Free `fillFree`, fractions of RAM); 5-column legend (gap 12) of
/// swatch (bordered) + `caption` label over a `pageTitle` value.
struct MemoryCompositionCard: View {
    @Environment(LiveModel.self) private var live

    struct Part {
        var label: String
        var bytes: UInt64?
        var color: Color
    }

    static func parts(_ m: MemorySnapshot) -> [Part] {
        [Part(label: "App memory", bytes: m.appMemory, color: TTColor.mem),
         Part(label: "Wired", bytes: m.wired, color: TTColor.memWired),
         Part(label: "Compressed", bytes: m.compressed, color: TTColor.memCompressed),
         Part(label: "Cached files", bytes: m.cachedFiles, color: TTColor.memCached),
         Part(label: "Free", bytes: m.free, color: TTColor.fillFree)]
    }

    var body: some View {
        let m = live.memory
        let parts = Self.parts(m)
        let total = Double(max(m.total, 1))
        let reason = unavailableReason(.memUsed, health: live.sensorHealth)
        TTCard(spacing: TTSpace.gridGap) {
            TTCardHeader("Composition") {
                if m.total > 0 { TTCaption(TTFormat.memory(m.total, style: .totalPrecise) + " unified memory") }
            }
            TTSegmentBar(parts.map { .init(Double($0.bytes ?? 0) / total, $0.color) }, style: .composition)
                .background(RoundedRectangle(cornerRadius: TTRadius.r5).fill(TTColor.fillTrack))
            HStack(alignment: .top, spacing: TTSpace.gridGap) {
                ForEach(parts, id: \.label) { p in
                    VStack(alignment: .leading, spacing: TTSpace.x2) {
                        HStack(spacing: TTSpace.x6) {
                            RoundedRectangle(cornerRadius: TTRadius.r2, style: .continuous).fill(p.color)
                                .overlay(RoundedRectangle(cornerRadius: TTRadius.r2, style: .continuous)
                                    .strokeBorder(TTColor.borderSwatch, lineWidth: TTStroke.hairline))
                                .frame(width: 8, height: 8)
                            Text(p.label).font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                        }
                        MetricValue(TTFormat.memory(p.bytes, style: .headline), unavailableReason: reason,
                                    font: TTFont.pageTitle)
                            .foregroundStyle(TTColor.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Memory pressure

/// DESIGN §3.7.3: gap 10, 240: legend [Normal `mem`][Warning `statusElevated`][Critical `statusCritical`]; area 0–100
/// (flex, fill × 150) colored by the OS level — the span i → i+1 takes sample i's level, line and fill switch
/// together; axis. (No fixed-% threshold bands: the color follows the OS level, DESIGN §6.16.)
struct MemoryPressureCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        RangeSeriesReader([.memPressure]) { s in
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Memory pressure") {
                    TTLegend(items: [("Normal", TTColor.mem), ("Warning", TTColor.statusElevated),
                                     ("Critical", TTColor.statusCritical)])
                }
                MemoryPressureChart(points: s[.memPressure], levels: Self.levels(s[.memPressure], live: live))
                    .frame(minHeight: 150, maxHeight: .infinity)
                TTTimeAxis(range: s.range, end: s.end)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Per-sample OS level. TODO(ICR 009): read `.memPressureLevel`; until then every sample takes the current level.
    static func levels(_ points: [SeriesPoint], live: LiveModel) -> [MemoryPressureLevel] {
        Array(repeating: live.memory.pressureLevel ?? .normal, count: points.count)
    }
}

/// Level-segmented area: one `TTAreaChart` per run of equal levels; each run includes the next sample so the span
/// i → i+1 is drawn in sample i's level (no blending at the change). Gridlines drawn once underneath.
struct MemoryPressureChart: View {
    let points: [SeriesPoint]
    let levels: [MemoryPressureLevel]

    /// Runs as (level, points with everything outside [start, end + 1] blanked).
    static func runs(_ points: [SeriesPoint], _ levels: [MemoryPressureLevel]) -> [(MemoryPressureLevel, [SeriesPoint])] {
        guard points.count == levels.count, !points.isEmpty else { return [] }
        var out: [(MemoryPressureLevel, [SeriesPoint])] = []
        var start = 0
        for i in 1...points.count where i == points.count || levels[i] != levels[start] {
            let end = min(i, points.count - 1)
            let masked = points.enumerated().map { j, p in
                (start...end).contains(j) ? p : SeriesPoint(time: p.time, value: nil)
            }
            out.append((levels[start], masked))
            start = i
        }
        return out
    }

    var body: some View {
        let runs = Self.runs(points, levels)
        ZStack {
            TTAreaChart([], color: .clear, yDomain: 0...1, grid: 4, showsCollecting: false)
            if ChartSegments.sampleCount(points) < 2 {
                TTEmptyState(.collecting(since: nil))
            } else {
                ForEach(runs.indices, id: \.self) { i in
                    TTAreaChart(runs[i].1, color: runs[i].0.chartColor, yDomain: 0...1,
                                fillOpacity: TTChartFill.memoryPressure, lineWidth: TTStroke.spark, showsCollecting: false)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Memory pressure")
    }
}

// MARK: - Swap

/// DESIGN §3.7.4: gap 8, 240: "Swap"; `title2` "1.20 GB" + `title2Unit` " of 2.00 GB"; sparkline (fill × 50,
/// 0…allocated, `memCompressed`); key-value list Swap-ins / Swap-outs / Swap files.
struct MemorySwapCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let m = live.memory
        let reason = unavailableReason(.swapUsed, health: live.sensorHealth)
        RangeSeriesReader([.swapUsed]) { s in
            TTCard(spacing: TTSpace.x8) {
                TTCardHeader("Swap")
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    MetricValue(TTFormat.memory(m.swapUsed, style: .swap), unavailableReason: reason, font: TTFont.title2)
                        .foregroundStyle(TTColor.textPrimary)
                    if let t = m.swapTotal {
                        Text(" of " + TTFormat.memory(t, style: .swap)).font(TTFont.title2Unit)
                            .foregroundStyle(TTColor.textSecondary)
                    }
                }
                TTAreaChart(s[.swapUsed], color: TTColor.memCompressed,
                            yDomain: 0...Double(max(m.swapTotal ?? 1, 1)), fillOpacity: TTChartFill.swap,
                            lineWidth: TTStroke.spark, showsCollecting: reason == nil)
                    .frame(height: 50)
                TTKeyValueList(rows: [
                    .init("Swap-ins", TTFormat.perSecond(m.swapInsPerSec), unavailableReason: reason),
                    .init("Swap-outs", TTFormat.perSecond(m.swapOutsPerSec), unavailableReason: reason),
                    .init("Swap files", TTFormat.count(m.swapFileCount), unavailableReason: reason),
                ])
                .fillBelow()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Top memory consumers

/// DESIGN §3.7.5: app groups by memory (phys footprint); template `minmax(0,2fr) 90 28`; coalition-only rows "—".
struct MemoryConsumersCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var selection: AppKey?
    @State private var sort: (column: String, descending: Bool) = ("memory", true)

    static func rows(_ live: LiveModel) -> [AppSample] {
        live.apps.filter { $0.identity.key != .other }
            .sorted { Double($0.memory ?? 0) > Double($1.memory ?? 0) }
    }

    var body: some View {
        let rows = Self.rows(live)
        let health = live.sensorHealth
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Top memory consumers") { PageLink("All processes", to: .processes) }
            FitRows { n in
                TTTable(rows: isSnapshot ? Array(rows.prefix(n)) : rows, columns: [
                    .init(id: "name", title: "Process", width: .fraction(2, min: 0)) { AnyView(AppNameCell(app: $0)) },
                    .init(id: "memory", title: "Memory", width: .fixed(90), alignment: .trailing,
                          sortKey: { $0.memory.map(Double.init) }) {
                        metricCell(TTFormat.memory($0.memory, style: .detail),
                                   reason: unavailableReason(.memory, $0, health: health))
                    },
                    .init(id: "actions", title: "", width: .fixed(28), alignment: .trailing) {
                        AnyView(TTRowActionsButton(target: $0.target, name: $0.name))
                    },
                ], selection: $selection, sort: $sort, rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                children: nil, style: TTTableStyle(emptyMessage: "No processes"), onDoubleClick: { app in
                    nav.selection = .app(app.identity.key)
                    nav.page = .processes
                })
            }
        }
    }
}
