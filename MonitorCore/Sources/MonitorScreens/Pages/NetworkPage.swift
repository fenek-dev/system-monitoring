import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.8 Network. Stat strip (5) · `grid3` (Throughput span 2 | Interfaces; 268) · Network by app (flex).
/// Subtitle "Wi-Fi 6E · 5 GHz · 1,201 Mbps link" / "Ethernet · 1,000 Mbps link". Rulings: no SSID, no Public IP;
/// "Today" = store total since local midnight; "This session" = `netRxSession + netTxSession`.
public struct NetworkPage: View {
    private let todayOverride: (rx: Double?, tx: Double?)?

    public init() { todayOverride = nil }

    /// Snapshot hook: the store's "Today" totals are read asynchronously, which a synchronous render never sees.
    init(today: (rx: Double?, tx: Double?)) { todayOverride = today }

    public var body: some View {
        NetworkPageContent(todayOverride: todayOverride)
    }
}

/// The page body reads nothing live: the subtitle and the once-a-minute "Today" loader are small child views, so a
/// network tick only re-evaluates the cards that show network values.
struct NetworkPageContent: View {
    let todayOverride: (rx: Double?, tx: Double?)?
    @State private var today: (rx: Double?, tx: Double?) = (nil, nil)

    var body: some View {
        FlexPage(minContentHeight: 82 + 268 + 130 + 2 * TTSpace.gridGap) {
            NetworkStatStrip(today: todayOverride ?? today)
            GridRow(columns: 3, spans: [2, 1], minHeight: 268) {
                NetworkThroughputCard()
                NetworkInterfacesCard()
            }
            NetworkAppsCard()
                .frame(minHeight: 130, maxHeight: .infinity, alignment: .top)
        }
        .processActionsHost()
        .background {
            NetworkSubtitle()
            if todayOverride == nil { NetworkTodayLoader(today: $today) }
        }
    }

    /// Local midnight → `end` in `timeZone` (DST-safe via `Calendar.startOfDay`).
    static func todayInterval(end: Date, timeZone: TimeZone) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return DateInterval(start: cal.startOfDay(for: end), end: end)
    }

    /// "Wi-Fi 6E · 5 GHz · 1,201 Mbps link" (no SSID); Ethernet-like: "Ethernet · 1,000 Mbps link".
    static func subtitle(_ n: NetworkSnapshot) -> String? {
        guard let primary = n.interfaces.first(where: \.isPrimary) else { return nil }
        if primary.kind == .wifi, let w = n.wifi {
            var parts = [w.standardLabel ?? "Wi-Fi"]
            if let band = w.bandGHz { parts.append(bandText(band)) }
            if let rate = w.txRateMbps { parts.append(TTFormat.linkRate(rate) + " link") }
            return parts.joined(separator: " · ")
        }
        var parts = [OverviewTiles.interfaceType(primary)]
        if let bps = primary.linkRateBps { parts.append(TTFormat.linkRate(bps / 1e6) + " link") }
        return parts.joined(separator: " · ")
    }

    /// "5 GHz", "2.4 GHz", "6 GHz".
    static func bandText(_ ghz: Double) -> String {
        TTFormat.number(ghz, digits: ghz == ghz.rounded() ? 0 : 1) + " GHz"
    }
}

/// Sets the page subtitle from the live network state (preference flows up to the shell header).
private struct NetworkSubtitle: View {
    @Environment(LiveModel.self) private var live
    var body: some View { Color.clear.pageHeader(subtitle: NetworkPageContent.subtitle(live.network)) }
}

/// Reloads "Today" (store totals since local midnight) once a minute; re-evaluates per tick but renders nothing.
private struct NetworkTodayLoader: View {
    @Binding var today: (rx: Double?, tx: Double?)
    @Environment(LiveModel.self) private var live
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var now
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Color.clear.task(id: Int((now ?? live.lastUpdate ?? Date()).timeIntervalSince1970 / 60)) {
            let interval = NetworkPageContent.todayInterval(end: now ?? Date(), timeZone: timeZone)
            async let rx = try? history.total(.netRx, in: interval)
            async let tx = try? history.total(.netTx, in: interval)
            let result = (await rx ?? nil, await tx ?? nil)
            guard !Task.isCancelled else { return }
            today = result
        }
    }
}

// MARK: - Stat strip

struct NetworkStatStrip: View {
    let today: (rx: Double?, tx: Double?)
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units

    var body: some View { TTStatStrip(Self.items(live, units: units, today: today)) }

    /// "—" tooltip for the rate cells when the sensor itself is fine: rates need two samples.
    static func fallbackRateReason(_ phase: LivePhase) -> String {
        if case .collecting = phase { return "Collecting — rates need two samples" }
        return "Not reported for the primary interface"
    }

    static func items(_ live: LiveModel, units: UnitPreferences, today: (rx: Double?, tx: Double?)) -> [TTStatStrip.Item] {
        let n = live.network
        let h = live.sensorHealth
        let primary = n.interfaces.first(where: \.isPrimary)
        let where_ = primary.map { "\(OverviewTiles.interfaceType($0)) · \($0.bsdName)" }
        let rateReason = unavailableReason(.netRx, health: h) ?? Self.fallbackRateReason(live.phase)
        var todayText: String?
        if let rx = today.rx, let tx = today.tx {
            todayText = "↓ " + TTFormat.storage(UInt64(max(0, rx)), style: .headline)
                + " · ↑ " + TTFormat.storage(UInt64(max(0, tx)), style: .headline)
        }
        let latencyReason = unavailableReason(.netLatency, health: h) ?? "No latency samples yet"
        return [
            .init(id: "down", label: "Download", value: TTFormat.rate(n.rxBps, units: units), detail: where_,
                  tint: TTColor.net, unavailableReason: rateReason),
            .init(id: "up", label: "Upload", value: TTFormat.rate(n.txBps, units: units), detail: where_,
                  unavailableReason: rateReason),
            .init(id: "today", label: "Today", value: todayText, unavailableReason: "No history stored today yet"),
            .init(id: "latency", label: "Latency", value: TTFormat.latency(n.latency?.lastRTTms ?? n.latency?.avgMs),
                  detail: n.latency.map { "to \($0.target)" }, unavailableReason: latencyReason),
            .init(id: "loss", label: "Packet loss", value: TTFormat.percent(n.latency?.lossFraction5m, digits: 1),
                  detail: "last 5 minutes", unavailableReason: latencyReason),
        ]
    }
}

// MARK: - Throughput

/// DESIGN §3.8.2: gap 10, 268: legend [Download · scale {N}][Upload · scale {N}]; `TTMirroredChart` 2 × 90
/// (↓ up, ↑ down, own nice scales); axis. A scale only grows within a Live session and re-evaluates on range change.
struct NetworkThroughputCard: View {
    @Environment(\.unitPreferences) private var units
    @State private var ceilings = Ceilings()

    struct Ceilings: Equatable {
        var range: HistoryRange?
        var up: Double = 0
        var down: Double = 0

        /// Live: grows within the session (a range change starts over). Stored ranges: the window's own nice max.
        func merged(range: HistoryRange, up: Double, down: Double) -> Ceilings {
            guard range == .live, self.range == range else { return Ceilings(range: range, up: up, down: down) }
            return Ceilings(range: range, up: max(self.up, up), down: max(self.down, down))
        }
    }

    /// Nice ceiling of a rate window in the display unit (bits setting → Mbps steps).
    static func ceiling(_ points: [SeriesPoint], units: UnitPreferences) -> Double {
        TTFormat.niceRateCeiling(points.lazy.compactMap(\.value).filter(\.isFinite).max() ?? 0, units: units)
    }

    var body: some View {
        RangeSeriesReader([.netRx, .netTx]) { s in
            let c = ceilings.merged(range: s.range, up: Self.ceiling(s[.netRx], units: units),
                                    down: Self.ceiling(s[.netTx], units: units))
            let down = ChartSeries(id: "rx", label: "Download · scale " + TTFormat.rateScale(c.up, units: units),
                                   color: TTColor.net, points: s[.netRx])
            let up = ChartSeries(id: "tx", label: "Upload · scale " + TTFormat.rateScale(c.down, units: units),
                                 color: TTColor.netUp, points: s[.netTx])
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Throughput") { TTLegend([down, up]) }
                TTMirroredChart(up: down, down: up, upScale: c.up, downScale: c.down)
                    .equatable()
                    .frame(height: 181)
                    .accessibilityLabel(ChartAccessibility.summary([down, up]))
                TTTimeAxis(range: s.range, end: s.end).fillBelow()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: c) { ceilings = c }
        }
    }
}

// MARK: - Interfaces

/// DESIGN §3.8.3: gap 8, 268: primary block (VStack gap 4, 8 bottom padding, 1-pt separator): "Wi-Fi · en0"
/// `sectionTitle` + badge "Active"; detail `caption` "5 GHz · channel 149 · −52 dBm · 1,201 Mbps" (no SSID); up to 2
/// inactive hardware ports ("Thunderbolt Ethernet · en5" | "Not connected"); key-value Local IP / Router (mono).
struct NetworkInterfacesCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let n = live.network
        let primary = n.interfaces.first(where: \.isPrimary)
        let others = Array(n.interfaces.filter { !$0.isPrimary && !$0.isUp }.prefix(2))
        let reason = unavailableReason(.netRx, health: live.sensorHealth) ?? "Not reported"
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Interfaces")
            if let primary {
                VStack(alignment: .leading, spacing: TTSpace.x4) {
                    HStack {
                        Text("\(primary.displayName) · \(primary.bsdName)").font(TTFont.sectionTitle)
                            .foregroundStyle(TTColor.textPrimary).lineLimit(1)
                        Spacer(minLength: 8)
                        TTBadge(primary.isUp ? "Active" : "Inactive",
                                dot: primary.isUp ? TTColor.statusCalm : TTColor.statusPaused)
                    }
                    if let detail = Self.detail(primary, wifi: n.wifi) {
                        Text(detail).font(TTFont.caption).foregroundStyle(TTColor.textSecondary).monospacedDigit()
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { TTSeparator() }
            } else {
                MetricValue(nil, unavailableReason: reason, font: TTFont.sectionTitle)
            }
            ForEach(others) { i in
                HStack {
                    Text("\(i.displayName) · \(i.bsdName)").font(TTFont.body13).foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text("Not connected").font(TTFont.caption).foregroundStyle(TTColor.textTertiary).lineLimit(1)
                }
                .padding(.bottom, 4)
            }
            TTKeyValueList(rows: [
                .init("Local IP", n.localIPv4 ?? primary?.ipv4, mono: true, unavailableReason: "No IPv4 address"),
                .init("Router", n.routerIPv4, mono: true, unavailableReason: "No default gateway"),
            ])
            .fillBelow()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Wi-Fi: "5 GHz · channel 149 · −52 dBm · 1,201 Mbps"; wired: "{link} Mbps".
    static func detail(_ i: InterfaceSnapshot, wifi: WiFiInfo?) -> String? {
        var parts: [String] = []
        if i.kind == .wifi, let w = wifi {
            if let b = w.bandGHz { parts.append(NetworkPageContent.bandText(b)) }
            if let c = w.channel { parts.append("channel \(TTFormat.count(c))") }
            if let r = w.rssi { parts.append(TTFormat.dBm(Double(r))) }
            if let t = w.txRateMbps { parts.append(TTFormat.linkRate(t)) }
        } else if let bps = i.linkRateBps {
            parts.append(TTFormat.linkRate(bps / 1e6))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Network by app

/// DESIGN §3.8.4: template `minmax(0,2fr) 100 100 110 90 28`: Process | Download | Upload | This session |
/// Connections | …; app groups by ↓+↑ descending; idle rates "—" without tooltip.
struct NetworkAppsCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.unitPreferences) private var units
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var selection: AppKey?
    @State private var sort: (column: String, descending: Bool) = ("down", true)
    @State private var cache = RankCache<AppSample>()

    nonisolated static func total(_ a: AppSample) -> Double? {
        if a.netRxBps == nil && a.netTxBps == nil { return nil }
        return (a.netRxBps ?? 0) + (a.netTxBps ?? 0)
    }

    nonisolated static func session(_ a: AppSample) -> UInt64? {
        if a.netRxSession == nil && a.netTxSession == nil { return nil }
        return (a.netRxSession ?? 0) + (a.netTxSession ?? 0)
    }

    /// The per-app flow sensor's reason when it is unavailable/disabled, else nil.
    static func flowsReason(_ health: [SensorID: SensorStatus]) -> String? {
        switch health[.networkFlows] {
        case .unavailable(let r)?, .disabled(let r)?: r
        default: nil
        }
    }

    /// Apps with network activity now or this session, by ↓+↑ descending (stable). With the flow sensor unavailable
    /// nothing has activity, so every app group is listed (cells show "—" with the reason) instead of an empty table.
    nonisolated static func rank(_ apps: [AppSample], flowsUnavailable: Bool) -> [AppSample] {
        let candidates = apps.filter {
            $0.identity.key != .other && (flowsUnavailable || (total($0) ?? 0) > 0 || (session($0) ?? 0) > 0)
        }
        return TTSort.stable(candidates) { total($0) ?? 0 }
    }

    static func rows(_ live: LiveModel) -> [AppSample] {
        rank(live.apps, flowsUnavailable: flowsReason(live.sensorHealth) != nil)
    }

    var body: some View {
        let health = live.sensorHealth
        let flowsReason = Self.flowsReason(health)
        let rows = cache.rows(version: live.appsVersion * 2 + (flowsReason == nil ? 0 : 1)) {
            Self.rank(live.apps, flowsUnavailable: flowsReason != nil)
        }
        let units = units
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Network by app") { PageLink("All processes", to: .processes) }
            FitRows { n in
                TTTable(rows: isSnapshot ? Array(rows.prefix(n)) : rows, columns: [
                    .init(id: "name", title: "Process", width: .fraction(2, min: 0)) { AnyView(AppNameCell(app: $0)) },
                    .init(id: "down", title: "Download", width: .fixed(100), alignment: .trailing) {
                        metricCell(TTFormat.rateCell($0.netRxBps, units: units),
                                   reason: unavailableReason(.netRx, $0, health: health))
                    },
                    .init(id: "up", title: "Upload", width: .fixed(100), alignment: .trailing) {
                        metricCell(TTFormat.rateCell($0.netTxBps, units: units),
                                   reason: unavailableReason(.netTx, $0, health: health))
                    },
                    .init(id: "session", title: "This session", width: .fixed(110), alignment: .trailing) {
                        metricCell(Self.session($0).map { TTFormat.storage($0, style: .detail) },
                                   reason: unavailableReason(.netRx, $0, health: health) ?? "Not measured this session")
                    },
                    .init(id: "connections", title: "Connections", width: .fixed(90), alignment: .trailing) {
                        metricCell($0.connectionCount.map { TTFormat.count($0) },
                                   reason: unavailableReason(.netRx, $0, health: health) ?? "Not reported")
                    },
                    .init(id: "actions", title: "", width: .fixed(28), alignment: .trailing) {
                        AnyView(TTRowActionsButton(target: $0.target, name: $0.name))
                    },
                ], selection: $selection, sort: $sort, rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                children: nil,
                style: TTTableStyle(sortsRows: false, emptyMessage: flowsReason ?? "No network activity"),
                onDoubleClick: { app in
                    nav.selection = .app(app.identity.key)
                    nav.page = .processes
                }, columnsVersion: tableColumnsVersion(live, units: units))   // cells capture units + health (M2)
            }
        }
    }
}
