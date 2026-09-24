import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.6 GPU. Stat strip (5) · charts `grid3` (Utilization & frequency span 2 | Neural Engine over Media
/// engines; min 293, or 250 without media engines) · GPU clients (flex). Subtitle is the shell default.
/// Rulings: no Renderer / per-app GPU memory columns; ANE in watts only; Media engines only when reported.
public struct GPUPage: View {
    public init() {}

    public var body: some View {
        GPUMediaGate()
    }
}

/// Reads only whether media-engine data exists and hands the layout a Bool, so a GPU tick re-evaluates this
/// one-line gate and the cards that show GPU values — not the whole page.
struct GPUMediaGate: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        GPUPageContent(hasMedia: !live.gpu.mediaEngines.isEmpty).equatable()
    }
}

struct GPUPageContent: View, Equatable {
    let hasMedia: Bool

    var body: some View {
        FlexPage(minContentHeight: 82 + (hasMedia ? 293 : 250) + 130 + 2 * TTSpace.gridGap) {
            GPUStatStrip()
            GridRow(columns: 3, spans: [2, 1], minHeight: hasMedia ? 293 : 250) {
                GPUUtilizationCard()
                VStack(spacing: TTSpace.gridGap) {
                    if hasMedia {
                        GPUNeuralEngineCard(flexes: false)
                        GPUMediaEnginesCard()
                    } else {
                        GPUNeuralEngineCard(flexes: true)   // fills the column; sparkline 250 − 94
                    }
                }
            }
            GPUClientsCard()
                .frame(minHeight: 130, maxHeight: .infinity, alignment: .top)
        }
        .processActionsHost()
    }
}

struct GPUStatStrip: View {
    @Environment(LiveModel.self) private var live

    var body: some View { TTStatStrip(Self.statItems(live)) }

    static func statItems(_ live: LiveModel) -> [TTStatStrip.Item] {
        let g = live.gpu
        let h = live.sensorHealth
        return [
            .init(id: "util", label: "Utilization", value: TTFormat.percent(g.usage), detail: "active residency",
                  tint: TTColor.gpu, unavailableReason: unavailableReason(.gpuUsage, health: h)),
            .init(id: "freq", label: "Frequency", value: TTFormat.frequency(g.frequencyMHz),
                  detail: g.maxFrequencyMHz.map { "of " + TTFormat.frequency($0) },
                  unavailableReason: unavailableReason(.gpuFrequency, health: h) ?? "GPU frequency not resolved"),
            .init(id: "power", label: "GPU power", value: TTFormat.watts(g.watts),
                  unavailableReason: unavailableReason(.gpuWatts, health: h) ?? "Not reported by IOReport"),
            .init(id: "memory", label: "GPU memory",
                  value: TTFormat.memory(g.allocatedMemory, style: .headline), detail: "allocated from unified memory",
                  unavailableReason: "Not reported by IOAccelerator"),
            .init(id: "cores", label: "Cores", value: TTFormat.count(g.coreCount ?? live.device.gpuCores),
                  unavailableReason: "GPU core count not reported"),
        ]
    }
}

// MARK: - Utilization & frequency

/// DESIGN §3.6.2: gap 10, stretches to the row: header legend [Utilization `gpu`][Frequency `gpuAlt`];
/// `TTDualChart` (flex, ≥ 160; frequency on 0…max MHz); axis.
struct GPUUtilizationCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        RangeSeriesReader([.gpuUsage, .gpuFrequency]) { s in
            let util = ChartSeries(id: "util", label: "Utilization", color: TTColor.gpu, points: s[.gpuUsage],
                                   fillOpacity: TTChartFill.gpuUtilization, lineWidth: TTStroke.spark)
            let freq = ChartSeries(id: "freq", label: "Frequency", color: TTColor.gpuAlt, points: s[.gpuFrequency],
                                   fillOpacity: 0, lineWidth: TTStroke.sparkThin,
                                   lineOpacity: TTChartFill.gpuFrequency, dash: TTChartFill.gpuFrequencyDash)
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Utilization & frequency") { TTLegend([util, freq]) }
                TTDualChart(solid: util, dashed: freq, yDomain: 0...1,
                            dashedDomain: live.gpu.maxFrequencyMHz.map { 0...$0 })
                    .equatable()
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .accessibilityLabel(ChartAccessibility.summary([util, freq]))
                TTTimeAxis(range: s.range, end: s.end)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Neural Engine

/// DESIGN §3.6.3 (watts only): gap 6, min 138: header "Neural Engine" + badge "{n} cores" (`power` dot);
/// `title2` watts | "idle" (< 0.05 W) / "active"; sparkline (fill × 44, auto ≥ 1 W, `power`). Without media
/// engines the card fills the column and the sparkline takes the extra height.
struct GPUNeuralEngineCard: View {
    let flexes: Bool
    @Environment(LiveModel.self) private var live

    var body: some View {
        let w = live.gpu.aneWatts
        let reason = unavailableReason(.aneWatts, health: live.sensorHealth) ?? "Not reported by IOReport"
        RangeSeriesReader([.aneWatts]) { s in
            TTCard(spacing: TTSpace.x6) {
                TTCardHeader("Neural Engine") {
                    if let n = live.device.neuralEngineCores { TTBadge("\(TTFormat.count(n)) cores", dot: TTColor.power) }
                }
                HStack(alignment: .firstTextBaseline) {
                    MetricValue(TTFormat.watts(w), unavailableReason: reason, font: TTFont.title2)
                        .foregroundStyle(TTColor.textPrimary)
                    Spacer(minLength: 8)
                    if let w {
                        Text(w < 0.05 ? "idle" : "active").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                    }
                }
                TTAreaChart(s[.aneWatts], color: TTColor.power, yDomain: W5a.autoDomain(s[.aneWatts], minimum: 1),
                            fillOpacity: TTChartFill.ane, lineWidth: TTStroke.spark,
                            showsCollecting: w != nil || unavailableReason(.aneWatts, health: live.sensorHealth) == nil)
                    .equatable()
                    .frame(minHeight: 44, maxHeight: flexes ? .infinity : 44)
            }
            .frame(minHeight: 138, maxHeight: flexes ? .infinity : nil, alignment: .top)
            .fixedSize(horizontal: false, vertical: !flexes)
        }
    }
}

// MARK: - Media engines

/// DESIGN §3.6.4: padding 14, gap 7, min 143; rows (VStack gap 5): name | "22%" or "idle" (`body12`), thin `gpu`
/// bar. Shown only when IOReport exposes media-engine residency; no codec suffix. Ruling (W6b): this chip exposes one
/// combined channel, reported as a single "Media engine" row — the card renders whatever rows the sensor gives.
struct GPUMediaEnginesCard: View {
    @Environment(LiveModel.self) private var live

    /// "idle" below 0.5 % (a rounded "0%" would read as a measurement), else integer percent.
    static func valueText(_ fraction: Double) -> String {
        fraction < 0.005 ? "idle" : TTFormat.percent(fraction)
    }

    var body: some View {
        let engines = live.gpu.mediaEngines
        TTCard(padding: TTSpace.cardPaddingMediaEngines, spacing: TTSpace.x7) {
            TTCardHeader("Media engines")
            ForEach(engines, id: \.name) { e in
                VStack(alignment: .leading, spacing: TTSpace.x5) {
                    HStack {
                        Text(e.name).foregroundStyle(TTColor.textPrimary)
                        Spacer(minLength: 8)
                        Text(Self.valueText(e.activeFraction))
                            .foregroundStyle(TTColor.textSecondary).monospacedDigit()
                    }
                    .font(TTFont.body12).lineLimit(1)
                    TTProgressBar(value: e.activeFraction, tint: TTColor.gpu)
                }
                .frame(maxHeight: e.name == engines.last?.name ? .infinity : nil, alignment: .top)   // extra below
            }
        }
        .frame(minHeight: 143, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - GPU clients

/// DESIGN §3.6.5: app groups with AGX GPU time; template `minmax(0,2fr) 80 90 28`: Process | % GPU | GPU time | ….
struct GPUClientsCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var selection: AppKey?
    @State private var sort: (column: String, descending: Bool) = ("gpu", true)

    @State private var cache = RankCache<AppSample>()

    /// GPU clients by % GPU descending (stable); pre-sorted, the table does not re-sort.
    nonisolated static func rank(_ apps: [AppSample]) -> [AppSample] {
        apps.enumerated()
            .filter { $0.element.identity.key != .other && (($0.element.gpuPercent ?? 0) > 0 || ($0.element.gpuTimeNs ?? 0) > 0) }
            .sorted { a, b in
                let x = a.element.gpuPercent ?? 0, y = b.element.gpuPercent ?? 0
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
    }

    static func rows(_ live: LiveModel) -> [AppSample] { rank(live.apps) }

    /// GPU time "—" tooltip keyed on the GPU time itself (not % GPU).
    static func gpuTimeReason(_ a: AppSample, health: [SensorID: SensorStatus]) -> String? {
        guard a.gpuTimeNs == nil else { return nil }
        return unavailableReason(.gpu, a, health: health) ?? "No GPU time recorded this session"
    }

    var body: some View {
        let rows = cache.rows(version: live.appsVersion) { Self.rank(live.apps) }
        let health = live.sensorHealth
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("GPU clients") { PageLink("All processes", to: .processes) }
            FitRows { n in
                TTTable(rows: isSnapshot ? Array(rows.prefix(n)) : rows, columns: [
                    .init(id: "name", title: "Process", width: .fraction(2, min: 0)) { AnyView(AppNameCell(app: $0)) },
                    .init(id: "gpu", title: "% GPU", width: .fixed(80), alignment: .trailing, sortKey: \.gpuPercent) {
                        metricCell(TTFormat.cpuPercent($0.gpuPercent, sign: false),
                                   reason: unavailableReason(.gpu, $0, health: health))
                    },
                    .init(id: "time", title: "GPU time", width: .fixed(90), alignment: .trailing) {
                        metricCell(TTFormat.cpuTime($0.gpuTimeNs), reason: Self.gpuTimeReason($0, health: health))
                    },
                    .init(id: "actions", title: "", width: .fixed(28), alignment: .trailing) {
                        AnyView(TTRowActionsButton(target: $0.target, name: $0.name))
                    },
                ], selection: $selection, sort: $sort, rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                children: nil, style: TTTableStyle(sortsRows: false, emptyMessage: "No GPU clients"), onDoubleClick: { app in
                    nav.selection = .app(app.identity.key)
                    nav.page = .processes
                })
            }
        }
    }
}
