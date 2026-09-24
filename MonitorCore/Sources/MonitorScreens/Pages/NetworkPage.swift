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

struct NetworkPageContent: View {
    let todayOverride: (rx: Double?, tx: Double?)?
    @Environment(LiveModel.self) private var live
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var now
    @Environment(\.timeZone) private var timeZone
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
        .forceQuitHost()
        .pageHeader(subtitle: Self.subtitle(live.network))
        .task(id: Self.minuteKey(now ?? live.lastUpdate ?? Date())) { await loadToday() }
    }

    /// Reloads "Today" once a minute (and at midnight, when the interval restarts).
    static func minuteKey(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 60) }

    private func loadToday() async {
        guard todayOverride == nil else { return }
        let end = now ?? Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let interval = DateInterval(start: cal.startOfDay(for: end), end: end)
        async let rx = try? history.total(.netRx, in: interval)
        async let tx = try? history.total(.netTx, in: interval)
        let result = (await rx ?? nil, await tx ?? nil)
        guard !Task.isCancelled else { return }
        today = result
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

// MARK: - Stat strip

struct NetworkStatStrip: View {
    let today: (rx: Double?, tx: Double?)
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units

    var body: some View { TTStatStrip(Self.items(live, units: units, today: today)) }

    static func items(_ live: LiveModel, units: UnitPreferences, today: (rx: Double?, tx: Double?)) -> [TTStatStrip.Item] {
        let n = live.network
        let h = live.sensorHealth
        let primary = n.interfaces.first(where: \.isPrimary)
        let where_ = primary.map { "\(OverviewTiles.interfaceType($0)) · \($0.bsdName)" }
        let rateReason = unavailableReason(.netRx, health: h)
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

        /// Grows within one range; a range change starts over.
        func merged(range: HistoryRange, up: Double, down: Double) -> Ceilings {
            guard self.range == range else { return Ceilings(range: range, up: up, down: down) }
            return Ceilings(range: range, up: max(self.up, up), down: max(self.down, down))
        }
    }

    var body: some View {
        RangeSeriesReader([.netRx, .netTx]) { s in
            let windowUp = W5a.rateDomain(s[.netRx]).upperBound
            let windowDown = W5a.rateDomain(s[.netTx]).upperBound
            let c = ceilings.merged(range: s.range, up: windowUp, down: windowDown)
            let down = ChartSeries(id: "rx", label: "Download · scale " + TTFormat.rateScale(c.up, units: units),
                                   color: TTColor.net, points: s[.netRx])
            let up = ChartSeries(id: "tx", label: "Upload · scale " + TTFormat.rateScale(c.down, units: units),
                                 color: TTColor.netUp, points: s[.netTx])
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Throughput") { TTLegend([down, up]) }
                TTMirroredChart(up: down, down: up, upScale: c.up, downScale: c.down)
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
    @State private var sort: (column: String, descending: Bool) = ("total", true)

    static func total(_ a: AppSample) -> Double? {
        if a.netRxBps == nil && a.netTxBps == nil { return nil }
        return (a.netRxBps ?? 0) + (a.netTxBps ?? 0)
    }

    static func session(_ a: AppSample) -> UInt64? {
        if a.netRxSession == nil && a.netTxSession == nil { return nil }
        return (a.netRxSession ?? 0) + (a.netTxSession ?? 0)
    }

    /// Apps with network activity now or this session, by ↓+↑ descending.
    static func rows(_ live: LiveModel) -> [AppSample] {
        live.apps.filter { $0.identity.key != .other && ((total($0) ?? 0) > 0 || (session($0) ?? 0) > 0) }
            .sorted { (total($0) ?? 0) > (total($1) ?? 0) }
    }

    var body: some View {
        let rows = Self.rows(live)
        let health = live.sensorHealth
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
                    .init(id: "total", title: "", width: .fixed(28), alignment: .trailing, sortKey: Self.total) {
                        AnyView(TTRowActionsButton(target: $0.target, name: $0.name))
                    },
                ], selection: $selection, sort: $sort, rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                children: nil, style: TTTableStyle(emptyMessage: "No network activity"), onDoubleClick: { app in
                    nav.selection = .app(app.identity.key)
                    nav.page = .processes
                })
            }
        }
    }
}
