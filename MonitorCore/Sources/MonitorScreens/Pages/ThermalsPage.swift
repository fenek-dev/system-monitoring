import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.9 Thermals: stat strip (4) · thermal pressure · Temperatures (span 2) + Fans · Sensors (flex).
/// Raw sensors (HID + SMC) arrive only while this page is visible (`UIVisibility.demand` → `.rawTemperatures`).
public struct ThermalsPage: View {
    private let showRawSensors: Bool
    private let openStrips: Set<String>

    public init() {
        showRawSensors = false
        openStrips = []
    }

    /// Tests/renders: start with the raw sensor list expanded and (optionally) some raw strips open.
    init(showRawSensors: Bool, openStrips: Set<String> = []) {
        self.showRawSensors = showRawSensors
        self.openStrips = openStrips
    }

    public var body: some View {
        SystemPageColumn {
            ThermalsStatStrip()
            ThermalPressureCard()
            SystemGrid3Row(minHeight: 244) {
                TemperaturesCard()
                FansCard()
            }
            SensorsCard(showRaw: showRawSensors, openStrips: openStrips)
        }
        .pageHeader(subtitle: "SoC sensors, fans and macOS thermal pressure")
    }
}

// MARK: - Stat strip

private struct ThermalsStatStrip: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units

    var body: some View {
        let t = live.thermals
        let health = live.sensorHealth
        let socCount = t.groups.first { $0.group == .soc }?.sensorCount
        TTStatStrip([
            .init(id: "soc", label: "SoC average", value: t.socAverage.map { TTFormat.temperature($0, units: units) },
                  // A blank sub keeps the strip's ≈82-pt height when every value is unavailable.
                  detail: socCount.map { "\($0) sensor\($0 == 1 ? "" : "s")" } ?? SystemPageCopy.blankSub,
                  tint: TTColor.thermal, unavailableReason: unavailableReason(.socTemp, health: health)),
            .init(id: "hottest", label: "Hottest sensor",
                  value: t.hottest.map { TTFormat.temperature($0.celsius, units: units) },
                  detail: t.hottest?.name, unavailableReason: unavailableReason(.socTemp, health: health)),
            .init(id: "pressure", label: "Thermal pressure", value: t.pressure.map(ThermalLevelCopy.title),
                  detail: t.pressure.map(ThermalLevelCopy.statSub), tint: t.pressure.map(ThermalLevelCopy.color),
                  unavailableReason: unavailableReason(.thermalPressure, health: health) ?? "Not reported by macOS"),
            fansItem(t.fans, health: health),
        ])
    }

    private func fansItem(_ fans: [FanSnapshot], health: [SensorID: SensorStatus]) -> TTStatStrip.Item {
        guard !fans.isEmpty else {
            let reason = live.device.fanCount == 0 ? "This Mac has no fans"
                : (unavailableReason(.fan1RPM, health: health) ?? "Fan speeds not reported")
            return .init(id: "fans", label: "Fans", value: nil, unavailableReason: reason)
        }
        let value = fans.map { TTFormat.number($0.rpm, digits: 0) }.joined(separator: " · ")
        return .init(id: "fans", label: "Fans", value: value, detail: "rpm")
    }
}

/// Thermal pressure copy (DESIGN §3.9 stat strip + scale).
enum ThermalLevelCopy {
    static func title(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    static func statSub(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal: "no throttling"
        case .fair: "mild fan boost"
        case .serious: "clock limiting likely"
        case .critical: "heavy throttling"
        }
    }

    static func scaleDetail(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal: "Full performance"
        case .fair: "Mild fan boost"
        case .serious: "Clock limiting likely"
        case .critical: "Heavy throttling"
        }
    }

    static func color(_ p: ThermalPressure) -> Color {
        switch p {
        case .nominal: TTColor.statusCalm
        case .fair: TTColor.statusFair
        case .serious: TTColor.statusElevated
        case .critical: TTColor.statusCritical
        }
    }
}

// MARK: - Thermal pressure

private struct ThermalPressureCard: View {
    @Environment(LiveModel.self) private var live

    private static let levels = ThermalPressure.allCases.map {
        TTThermalScale.Level(title: ThermalLevelCopy.title($0), detail: ThermalLevelCopy.scaleDetail($0),
                             color: ThermalLevelCopy.color($0))
    }

    var body: some View {
        let pressure = live.thermals.pressure
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Thermal pressure") {
                TTCaption("Reported by macOS · changes are logged to History")
            }
            TTThermalScale(levels: Self.levels, current: pressure?.rawValue)
                .helpIfPresent(pressure == nil
                    ? (unavailableReason(.thermalPressure, health: live.sensorHealth) ?? "Not reported by macOS") : nil)
        }
    }
}

// MARK: - Temperatures chart

private struct TemperaturesCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.unitPreferences) private var units
    @Environment(\.now) private var fixedNow
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]

    static let metrics: [HistoryMetric] = [.cpuPTemp, .gpuTemp, .batteryTemp]

    var body: some View {
        let range = nav.range
        let end = fixedNow ?? live.lastUpdate ?? Date()
        let points = { (m: HistoryMetric) in
            ThermalChartData.sanitized(SystemRangeSeries.points(m, range: range, live: live, stored: stored))
        }
        let series = [
            ChartSeries(id: "p", label: "P-cores", color: TTColor.thermal, points: points(.cpuPTemp),
                        fillOpacity: nil, lineWidth: TTStroke.sparkHeavy),
            ChartSeries(id: "gpu", label: "GPU", color: TTColor.thermalGPU, points: points(.gpuTemp),
                        fillOpacity: nil, lineWidth: TTStroke.spark),
            ChartSeries(id: "battery", label: "Battery", color: TTColor.thermalBattery, points: points(.batteryTemp),
                        fillOpacity: nil, lineWidth: TTStroke.spark),
        ]
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Temperatures") { TTLegend(series) }
            Group {
                if let reason = ThermalChartData.unavailableReason(series, health: live.sensorHealth) {
                    SystemChartUnavailable(reason: reason)
                } else {
                    TTLineChart(series, yDomain: ThermalChartData.domain(series)) {
                        TTFormat.temperatureCompact($0, units: units)
                    }
                }
            }
            .frame(height: 150)
            // The plot keeps its 150; extra row height goes under the axis (reference).
            VStack(spacing: 0) {
                TTTimeAxis(range: range, end: end).padding(.leading, 34)
                Spacer(minLength: 0)
            }
        }
        .rangeSeries(Self.metrics, range: range, end: end, into: $stored)
    }
}

enum ThermalChartData {
    /// DESIGN §5.10 Thermals chart domain, 40–105 °C (labels follow the unit setting).
    static let baseDomain: ClosedRange<Double> = 40...105

    /// Ruling: the lower bound drops below 40 so no real sample is clamped to the axis floor:
    /// `min(40, floor(min visible sample) − 5)` rounded down to a multiple of 10. The upper bound stays 105.
    static func domain(_ series: [ChartSeries]) -> ClosedRange<Double> {
        let lowest = series.lazy.flatMap(\.points).compactMap(\.value).filter(\.isFinite).min()
        guard let lowest else { return baseDomain }
        let lower = min(baseDomain.lowerBound, ((lowest.rounded(.down) - 5) / 10).rounded(.down) * 10)
        return lower...baseDomain.upperBound
    }

    /// Missing readings are gaps: nil, non-finite and ≤ 0 °C samples (a sensor that reports nothing) become nil,
    /// so they are never drawn at 0 or clamped to the 40° floor.
    static func sanitized(_ points: [SeriesPoint]) -> [SeriesPoint] {
        points.map { p in
            guard let v = p.value, v.isFinite, v > 0 else { return SeriesPoint(time: p.time, value: nil) }
            return p
        }
    }

    /// The chart's unavailable state: the SoC sensors (SMC/HID) behind the P-core and GPU series are down and
    /// neither series has data. A battery-only reading (AppleSmartBattery, typically below the 40° floor) would
    /// just be a flat line on the floor, so it doesn't keep the chart. nil → draw the chart.
    static func unavailableReason(_ series: [ChartSeries], health: [SensorID: SensorStatus]) -> String? {
        let soc = series.filter { $0.id != "battery" }
        guard soc.allSatisfy({ ChartSegments.sampleCount($0.points) == 0 }) else { return nil }
        // Groups come from the SMC catalog only (ruling), so its status is the reason.
        return MonitorModel.unavailableReason(.cpuPTemp, health: health)
            ?? MonitorModel.unavailableReason(.gpuTemp, health: health)
    }
}

// MARK: - Fans

private struct FansCard: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let fans = live.thermals.fans
        TTCard(spacing: TTSpace.x12) {
            HStack(spacing: TTSpace.x8) {
                TTIcon(.fan, size: 16, color: TTColor.thermal)
                Text("Fans").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20)
            if fans.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: TTSpace.x12) {
                    ForEach(FansCardLabels.labeled(fans)) { TTFanGauge(fan: $0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if live.device.fanCount == 0 {
            TTEmptyState(.empty("This Mac has no fans"))
        } else {
            TTEmptyState(.unavailable(unavailableReason(.fan1RPM, health: live.sensorHealth) ?? "Fan speeds not reported"))
        }
    }
}

enum FansCardLabels {
    /// DESIGN §3.9: "Left fan" / "Right fan", or "Fan" when there is one.
    static func labeled(_ fans: [FanSnapshot]) -> [FanSnapshot] {
        fans.enumerated().map { i, fan in
            var f = fan
            switch fans.count {
            case 1: f.name = "Fan"
            case 2: f.name = i == 0 ? "Left fan" : "Right fan"
            default: f.name = "Fan \(i + 1)"
            }
            return f
        }
    }
}

// MARK: - Sensors table

/// One line of the sensors table: a curated group (depth 0) or a raw sensor (depth 1, raw mode only).
struct ThermalSensorLine: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String?
    var detailHelp: String?
    var celsius: Double?
    var peak: Double?
    var depth: Int
    var parity: Int
}

/// Last-hour maxima per sensor in 15-s buckets (the 1H display bucket, 240 points), recorded while the page is
/// open, with a running peak per key (recomputed only when a bucket leaves the window). Covers the raw sensors
/// and the groups the store does not record (Airflow). Not observable: the table re-reads it whenever
/// `LiveModel.thermals` changes.
@MainActor final class ThermalPeakTracker {
    static let bucketSeconds = 15.0
    static let bucketCount = 240
    private var buckets: [String: [(slot: Int, value: Double)]] = [:]
    private var peaks: [String: Double] = [:]

    var isEmpty: Bool { buckets.isEmpty }

    func record(_ key: String, _ value: Double, at time: Date) {
        guard value.isFinite else { return }
        let slot = Int((time.timeIntervalSince1970 / Self.bucketSeconds).rounded(.down))
        var list = buckets[key] ?? []
        if let last = list.last, last.slot == slot {
            list[list.count - 1].value = max(last.value, value)
        } else if let last = list.last, slot < last.slot {
            return                                        // out of order (seeded history newer than this)
        } else {
            list.append((slot, value))
        }
        if let first = list.first, first.slot <= slot - Self.bucketCount {
            list.removeAll { $0.slot <= slot - Self.bucketCount }
            peaks[key] = list.map(\.value).max()
        } else {
            peaks[key] = max(peaks[key] ?? value, value)
        }
        buckets[key] = list
    }

    /// Seeds a key from an existing series (the live ring when the page opens).
    func seed(_ key: String, _ points: [SeriesPoint]) {
        for p in points { if let v = p.value { record(key, v, at: p.time) } }
    }

    func peak(_ key: String) -> Double? { peaks[key] }

    /// 240 slots ending at `end` (nil = gap), for the 1H sparkline strip.
    func points(_ key: String, end: Date) -> [SeriesPoint] {
        let endSlot = Int((end.timeIntervalSince1970 / Self.bucketSeconds).rounded(.down))
        let byslot = Dictionary((buckets[key] ?? []).map { ($0.slot, $0.value) }, uniquingKeysWith: max)
        return (0..<Self.bucketCount).map { i in
            let slot = endSlot - Self.bucketCount + 1 + i
            return SeriesPoint(time: Date(timeIntervalSince1970: Double(slot) * Self.bucketSeconds), value: byslot[slot])
        }
    }

    func prune(keeping keys: Set<String>) {
        for k in buckets.keys where !keys.contains(k) {
            buckets[k] = nil
            peaks[k] = nil
        }
    }
}

enum ThermalGroupCopy {
    /// Ruling: the E-core group mapping is low confidence.
    static let eCoreApproximate = "Estimated from SMC sensors; E-core mapping is approximate"

    /// DESIGN §3.9 group names, in display order.
    static func name(_ g: TemperatureGroup) -> String {
        switch g {
        case .cpuPerformance: "CPU performance cores"
        case .cpuEfficiency: "CPU efficiency cores"
        case .gpu: "GPU cluster"
        case .soc: "SoC package"
        case .ssd: "SSD"
        case .battery: "Battery"
        case .airflow: "Airflow"
        case .other: "Other"
        }
    }

    /// Detail next to the name: "avg of 8" for averaged clusters, else the source ("PMU die", "NAND", "cell avg").
    /// E-cores add "approximate" (ruling).
    static func detail(_ g: TemperatureGroupSnapshot) -> String? {
        let avg = g.sensorCount > 1 ? "avg of \(g.sensorCount)" : nil
        switch g.group {
        case .soc: return "PMU die"
        case .ssd: return "NAND"
        case .battery: return "cell avg"
        case .airflow: return avg ?? "intake"
        case .cpuEfficiency: return [avg, "approximate"].compactMap { $0 }.joined(separator: " · ")
        case .cpuPerformance, .gpu, .other: return avg
        }
    }

    static func detailHelp(_ g: TemperatureGroup) -> String? { g == .cpuEfficiency ? eCoreApproximate : nil }

    /// Store metric holding the group's average (its peak comes from `historyProvider.peak`).
    static func metric(_ g: TemperatureGroup) -> HistoryMetric? {
        switch g {
        case .cpuPerformance: .cpuPTemp
        case .cpuEfficiency: .cpuETemp
        case .gpu: .gpuTemp
        case .soc: .socTemp
        case .ssd: .ssdTemp
        case .battery: .batteryTemp
        case .airflow, .other: nil
        }
    }

    static func groupKey(_ g: TemperatureGroup) -> String { "g:\(g.rawValue)" }
    static func rawKey(_ s: RawTemperature) -> String { "r:\(s.source.rawValue):\(s.group.rawValue):\(s.name)" }
}

private struct SensorsCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.historyProvider) private var history
    @Environment(\.now) private var fixedNow
    @State private var showRaw: Bool
    @State private var openStrips: Set<String>
    @State private var storePeaks: [HistoryMetric: Double] = [:]
    @State private var tracker = ThermalPeakTracker()

    init(showRaw: Bool, openStrips: Set<String>) {
        _showRaw = State(initialValue: showRaw)
        _openStrips = State(initialValue: openStrips)
    }

    var body: some View {
        let t = live.thermals
        let end = fixedNow ?? live.lastUpdate ?? Date()
        let lines = SensorsCardLines.lines(t, showRaw: showRaw, peak: peak)
        TTCard(spacing: TTSpace.x6) {
            TTCardHeader("Sensors") {
                HStack(spacing: TTSpace.x12) {
                    if !t.groups.isEmpty {
                        TTCaption(SensorsCardLines.caption(t))
                            .helpIfPresent(t.approximateMapping
                                ? "This Mac model isn't in the sensor catalog; groups use an approximate mapping" : nil)
                    }
                    if !t.sensors.isEmpty || showRaw {
                        TTLink(showRaw ? "Hide raw sensors" : "Show raw sensors") { showRaw.toggle() }
                    }
                }
            }
            ThermalSensorTable(lines: lines, openStrips: $openStrips, emptyMessage: emptyMessage,
                               strip: { tracker.points($0, end: end) })
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: live.thermalsVersion, initial: true) { record(end: end) }
        .task(id: Int(end.timeIntervalSince1970 / 60)) { await loadPeaks(end: end) }
    }

    private var emptyMessage: String {
        unavailableReason(.socTemp, health: live.sensorHealth) ?? "No temperature sensors reported"
    }

    /// Peak (1 h) = max of the store peak, the running peak recorded on this page (seeded from the live ring),
    /// and the current value.
    private func peak(key: String, metric: HistoryMetric?, now: Double?) -> Double? {
        [now, tracker.peak(key), metric.flatMap { storePeaks[$0] }].compactMap { $0 }.max()
    }

    private func record(end: Date) {
        let t = live.thermals
        if tracker.isEmpty {
            for g in t.groups {
                if let m = ThermalGroupCopy.metric(g.group) {
                    tracker.seed(ThermalGroupCopy.groupKey(g.group), live.series(m, window: .seconds(3_600)))
                }
            }
        }
        var keys = Set<String>()
        for g in t.groups {
            let k = ThermalGroupCopy.groupKey(g.group)
            tracker.record(k, g.average, at: end)
            keys.insert(k)
        }
        for s in t.sensors {
            let k = ThermalGroupCopy.rawKey(s)
            tracker.record(k, s.celsius, at: end)
            keys.insert(k)
        }
        if !t.sensors.isEmpty { tracker.prune(keeping: keys) }
    }

    private func loadPeaks(end: Date) async {
        let interval = DateInterval(start: end.addingTimeInterval(-3_600), end: end)
        var result: [HistoryMetric: Double] = [:]
        for g in TemperatureGroup.allCases {
            guard let m = ThermalGroupCopy.metric(g), let p = try? await history.peak(m, in: interval) else { continue }
            result[m] = p
        }
        if !Task.isCancelled, result != storePeaks { storePeaks = result }
    }
}

enum SensorsCardLines {
    /// "7 groups · 38 raw sensors" (ICR-6: "Approximate mapping · …" when the model isn't in the catalog).
    static func caption(_ t: ThermalSnapshot) -> String {
        let g = t.groups.count
        var parts: [String] = []
        if t.approximateMapping { parts.append("Approximate mapping") }
        parts.append("\(g) group\(g == 1 ? "" : "s")")
        if !t.sensors.isEmpty { parts.append("\(t.sensors.count) raw sensor\(t.sensors.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Groups in DESIGN order; in raw mode each group is followed by its raw sensors (hottest first). Raw sensors
    /// of groups the catalog did not report go under a trailing "Other" group. `peak(key, storeMetric, now)`.
    static func lines(_ t: ThermalSnapshot, showRaw: Bool,
                      peak: (_ key: String, _ metric: HistoryMetric?, _ now: Double?) -> Double? = { _, _, now in now })
        -> [ThermalSensorLine] {
        let order = Dictionary(uniqueKeysWithValues: TemperatureGroup.allCases.enumerated().map { ($1, $0) })
        var groups = t.groups.sorted { (order[$0.group] ?? 99) < (order[$1.group] ?? 99) }
        let known = Set(t.groups.map(\.group))
        let orphans = showRaw ? t.sensors.filter { !known.contains($0.group) } : []
        if !orphans.isEmpty {
            let avg = orphans.map(\.celsius).reduce(0, +) / Double(orphans.count)
            groups.append(TemperatureGroupSnapshot(group: .other, average: avg,
                                                   maximum: orphans.map(\.celsius).max() ?? avg,
                                                   sensorCount: orphans.count))
        }
        let raw = showRaw ? Dictionary(grouping: t.sensors, by: \.group) : [:]
        var out: [ThermalSensorLine] = []
        for (i, g) in groups.enumerated() {
            let key = ThermalGroupCopy.groupKey(g.group)
            out.append(ThermalSensorLine(id: key, name: ThermalGroupCopy.name(g.group), detail: ThermalGroupCopy.detail(g),
                                         detailHelp: ThermalGroupCopy.detailHelp(g.group), celsius: g.average,
                                         peak: peak(key, ThermalGroupCopy.metric(g.group), g.average),
                                         depth: 0, parity: i % 2))
            guard showRaw else { continue }
            let members = g.group == .other && !known.contains(.other) ? orphans : (raw[g.group] ?? [])
            for s in members.sorted(by: { $0.celsius > $1.celsius }) {
                let k = ThermalGroupCopy.rawKey(s)
                out.append(ThermalSensorLine(id: k, name: s.name, detail: s.source == .hid ? "HID" : "SMC",
                                             celsius: s.celsius, peak: peak(k, nil, s.celsius), depth: 1, parity: i % 2))
            }
        }
        return out
    }

    /// Raw rows toggle their sparkline strip; group rows do nothing.
    static func toggled(_ open: Set<String>, _ line: ThermalSensorLine) -> Set<String> {
        guard line.depth > 0 else { return open }
        var s = open
        if s.contains(line.id) { s.remove(line.id) } else { s.insert(line.id) }
        return s
    }
}

/// DESIGN §3.9 sensors table: template `minmax(0,2fr) 70 80 minmax(0,2fr)`, header 26, rows 28 (children at indent
/// 20), thin `thermal` bar over 20–105 °C. Clicking a raw row toggles a 30-pt 1H sparkline strip under it.
private struct ThermalSensorTable: View {
    let lines: [ThermalSensorLine]
    @Binding var openStrips: Set<String>
    let emptyMessage: String
    let strip: (String) -> [SeriesPoint]
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        GeometryReader { geo in
            let w = Self.widths(geo.size.width - 2 * TTSpace.tableRowInset)
            VStack(alignment: .leading, spacing: 0) {
                header(w)
                if lines.isEmpty {
                    Text(emptyMessage).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1).frame(maxWidth: .infinity).frame(height: 80)
                } else if isSnapshot {
                    // Whole rows only (no clipped sliver).
                    let limit = SystemFittedRows<EmptyView>.limit(height: geo.size.height, rowHeight: 28, headerHeight: 26)
                    rows(w, Array(lines.prefix(limit))).padding(.top, TTSpace.x4)
                } else {
                    ScrollView(.vertical) { rows(w, lines).padding(.top, TTSpace.x4) }
                        .scrollIndicators(.automatic)
                }
            }
        }
        .clipped()
    }

    /// Name and bar share the width left after the fixed columns (2fr each) and three 12-pt gaps.
    static func widths(_ available: CGFloat) -> [CGFloat] {
        let flex = max(0, available - 70 - 80 - 3 * TTSpace.tableCellGap) / 2
        return [flex, 70, 80, flex]
    }

    private func header(_ w: [CGFloat]) -> some View {
        HStack(spacing: TTSpace.tableCellGap) {
            headerCell("Sensor", w[0], .leading)
            headerCell("Now", w[1], .trailing)
            headerCell("Peak (1 h)", w[2], .trailing)
            Color.clear.frame(width: w[3], height: 1)
        }
        .padding(.horizontal, TTSpace.tableRowInset)
        .frame(height: 26)
        .overlay(alignment: .bottom) { TTSeparator() }
    }

    private func headerCell(_ title: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(title).font(TTFont.captionMedium).foregroundStyle(TTColor.textSecondary).lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func rows(_ w: [CGFloat], _ lines: [ThermalSensorLine]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                VStack(spacing: 0) {
                    ThermalSensorRow(line: line, widths: w)
                        .equatable()
                        .contentShape(Rectangle())
                        .onTapGesture { openStrips = SensorsCardLines.toggled(openStrips, line) }
                    if line.depth > 0, openStrips.contains(line.id) {
                        TTAreaChart(strip(line.id), color: TTColor.thermal, yDomain: 20...105,
                                    fillOpacity: TTChartFill.timeline, lineWidth: TTStroke.sparkThin)
                            .frame(height: 30)
                            .padding(.leading, TTSpace.tableRowInset + 20)
                            .padding(.trailing, TTSpace.tableRowInset)
                            .padding(.bottom, TTSpace.x6)
                    }
                }
                .background(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
                    .fill(line.parity == 1 ? TTColor.fillZebra : .clear))
            }
        }
    }
}

enum ThermalSensorBar {
    /// DESIGN §3.9 bar: `(t − 20) / 85` clamped to 0…1 (a 20–105 °C scale).
    static func fraction(_ c: Double?) -> Double? { c.map { min(max(($0 - 20) / 85, 0), 1) } }
}

private struct ThermalSensorRow: View, Equatable {
    let line: ThermalSensorLine
    let widths: [CGFloat]
    @Environment(\.unitPreferences) private var units
    @State private var hovering = false

    nonisolated static func == (a: Self, b: Self) -> Bool { a.line == b.line && a.widths == b.widths }

    var body: some View {
        let child = line.depth > 0
        HStack(spacing: TTSpace.tableCellGap) {
            HStack(spacing: TTSpace.x8) {
                Text(line.name).font(TTFont.body12)
                    .foregroundStyle(child ? TTColor.textSecondary : TTColor.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                if let d = line.detail {
                    Text(d).font(TTFont.caption).foregroundStyle(TTColor.textTertiary).lineLimit(1)
                        .layoutPriority(-1)
                        .helpIfPresent(line.detailHelp)
                }
            }
            .padding(.leading, child ? 20 : 0)
            .frame(width: widths[0], alignment: .leading)
            MetricValue(line.celsius.map { TTFormat.temperature($0, units: units) }, font: TTFont.body12)
                .foregroundStyle(TTColor.textPrimary)
                .frame(width: widths[1], alignment: .trailing)
            MetricValue(line.peak.map { TTFormat.temperature($0, units: units) },
                        unavailableReason: line.peak == nil ? "No history yet" : nil, font: TTFont.body12)
                .foregroundStyle(TTColor.textSecondary)
                .frame(width: widths[2], alignment: .trailing)
            TTProgressBar(value: ThermalSensorBar.fraction(line.celsius), tint: TTColor.thermal)
                .frame(width: widths[3])
        }
        .padding(.horizontal, TTSpace.tableRowInset)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
            .fill(hovering ? TTColor.fillHover : .clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - W5b shared page helpers (Thermals, Power & Battery, Disk)

enum SystemPageCopy {
    /// Non-breaking space: keeps a stat cell's sub-line height when its value is unavailable.
    static let blankSub = "\u{00A0}"
}

/// A page chart whose sources are unavailable: "—" (`textTertiary`) over the sensor's reason, centered in the
/// chart frame (DESIGN §3.15 unavailable value + reason, e.g. "Disabled after a crash").
struct SystemChartUnavailable: View {
    let reason: String

    var body: some View {
        VStack(spacing: TTSpace.x4) {
            Text(TTFormat.unavailable).font(TTFont.stat).foregroundStyle(TTColor.textTertiary)
            Text(reason).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(reason)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unavailable, \(reason)")
    }
}

enum SystemPageSort {
    /// Stable descending sort by `key`, nil/non-finite last (the tables' fixed headline sort).
    static func descending<T>(_ items: [T], by key: (T) -> Double?) -> [T] {
        items.enumerated()
            .map { (i: $0.offset, k: key($0.element).flatMap { $0.isFinite ? $0 : nil }, v: $0.element) }
            .sorted { a, b in
                switch (a.k, b.k) {
                case let (x?, y?): x != y ? x > y : a.i < b.i
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): a.i < b.i
                }
            }
            .map(\.v)
    }
}

/// Bottom table cards: snapshot renders show only whole rows (no clipped sliver of a last row); live tables pass
/// every row and scroll. `content(limit)` receives the row budget for the height it is given.
struct SystemFittedRows<Content: View>: View {
    let rowHeight: CGFloat
    var headerHeight: CGFloat = 26
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.isSnapshot) private var isSnapshot

    static func limit(height: CGFloat, rowHeight: CGFloat, headerHeight: CGFloat) -> Int {
        max(0, Int(((height - headerHeight - TTSpace.x4) / rowHeight).rounded(.down)))
    }

    var body: some View {
        GeometryReader { geo in
            content(isSnapshot ? Self.limit(height: geo.size.height, rowHeight: rowHeight, headerHeight: headerHeight)
                               : Int.max)
        }
        .clipped()
    }
}

/// DESIGN §3.0 content: padding 20, VStack gap 12, fills the page area; the bottom card is the flex child and
/// scrolls its own rows (no page-level ScrollView, so nested scrolling never collapses the table).
struct SystemPageColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.gridGap) { content }
            .padding(TTSpace.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTColor.bgWindow)
    }
}

/// `grid3` row of two cells: span 2 (676 at the default width) + one column (332). The row is as tall as its
/// tallest cell (at least `minHeight`) and both cells are stretched to it (DESIGN §3.0 height rule).
struct SystemGrid3Row: Layout {
    let minHeight: CGFloat

    static func widths(_ total: CGFloat) -> (span2: CGFloat, single: CGFloat) {
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

/// Range → chart points: Live reads the `LiveModel` ring (60 s); other ranges read the store, bucketed to the
/// range's display bucket (`bucket: nil`), reloaded once per bucket.
enum SystemRangeSeries {
    struct Key: Hashable {
        let range: HistoryRange
        let slot: Int

        init(range: HistoryRange, end: Date) {
            self.range = range
            let bucket = Double(range.displayBucket.components.seconds)
            slot = range == .live ? 0 : Int(end.timeIntervalSince1970 / max(bucket, 1))
        }
    }

    @MainActor static func points(_ metric: HistoryMetric, range: HistoryRange, live: LiveModel,
                                  stored: [HistoryMetric: [SeriesPoint]]) -> [SeriesPoint] {
        range == .live ? live.series(metric) : (stored[metric] ?? [])
    }

    /// Store series for a non-live range; Live → empty (the ring is read directly).
    static func load(_ metrics: [HistoryMetric], range: HistoryRange, end: Date,
                     history: any HistoryProvider) async -> [HistoryMetric: [SeriesPoint]] {
        guard range != .live else { return [:] }
        return (try? await history.series(metrics, range: range, end: end, bucket: nil)) ?? [:]
    }
}

private struct RangeSeriesLoader: ViewModifier {
    let metrics: [HistoryMetric]
    let range: HistoryRange
    let end: Date
    @Binding var stored: [HistoryMetric: [SeriesPoint]]
    @Environment(\.historyProvider) private var history

    func body(content: Content) -> some View {
        content.task(id: SystemRangeSeries.Key(range: range, end: end)) {
            let result = await SystemRangeSeries.load(metrics, range: range, end: end, history: history)
            if !Task.isCancelled, result != stored { stored = result }
        }
    }
}

extension View {
    /// Loads store series for non-live ranges into `stored` (see `SystemRangeSeries`).
    func rangeSeries(_ metrics: [HistoryMetric], range: HistoryRange, end: Date,
                     into stored: Binding<[HistoryMetric: [SeriesPoint]]>) -> some View {
        modifier(RangeSeriesLoader(metrics: metrics, range: range, end: end, stored: stored))
    }

    /// `.help(text)` only when there is text (no empty tooltips).
    @ViewBuilder func helpIfPresent(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// Page-level process-action feedback shared by the Power and Disk tables: the Force Quit confirm
/// (`TTConfirmDialog`) and result toasts ("{name} quit.", eject failures). The environment handlers are created
/// once, so row menus are not invalidated on every tick.
@MainActor @Observable final class ProcessActionFeedback {
    struct Pending: Equatable {
        var target: ProcessTarget
        var name: String
    }

    var pending: Pending?
    var toast: String?
    @ObservationIgnored private(set) var requestForceQuit: (@MainActor @Sendable (ProcessTarget) -> Void)?
    @ObservationIgnored private(set) var onResult: (@MainActor @Sendable (ProcessTarget, ActionResult) -> Void)?

    init() {
        requestForceQuit = { [weak self] target in
            self?.pending = Pending(target: target, name: Self.name(of: target))
        }
        onResult = { [weak self] target, result in
            self?.show(Self.toast(name: Self.name(of: target), forced: false, result: result))
        }
    }

    func show(_ text: String?) {
        if let text { toast = text }
    }

    func cancel() { pending = nil }

    /// Confirmed Force Quit: runs the action, clears the dialog and shows the result.
    func confirm(using actions: ProcessActions) async {
        guard let p = pending else { return }
        pending = nil
        show(Self.toast(name: p.name, forced: true, result: await actions.forceQuit(p.target)))
    }

    static func name(of target: ProcessTarget) -> String {
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

private struct ProcessActionFeedbackModifier: ViewModifier {
    let feedback: ProcessActionFeedback
    @Environment(\.processActions) private var actions

    func body(content: Content) -> some View {
        content
            .environment(\.requestForceQuit, feedback.requestForceQuit)
            .environment(\.onProcessActionResult, feedback.onResult)
            .overlay {
                // TTConfirmDialog covers the page area (the shell has no window-level host).
                if let p = feedback.pending {
                    TTConfirmDialog(
                        title: "Force quit “\(p.name)”?",
                        message: "Unsaved changes will be lost. The process ends immediately without cleanup.",
                        confirmTitle: "Force Quit",
                        onConfirm: { [feedback, actions] in Task { await feedback.confirm(using: actions) } },
                        onCancel: { [feedback] in feedback.cancel() })
                        .transition(TTConfirmDialog.transition)
                }
            }
    }
}

extension View {
    /// Installs the Force Quit confirm + result handlers of `feedback` for the row menus and inline buttons below.
    func processActionFeedback(_ feedback: ProcessActionFeedback) -> some View {
        modifier(ProcessActionFeedbackModifier(feedback: feedback))
    }
}

/// The current toast (`TTToast`), removed after `TTToast.lifetime`. Placed in the table card header.
struct ProcessActionToast: View {
    let feedback: ProcessActionFeedback

    var body: some View {
        Group {
            if let text = feedback.toast { TTToast(text) }
        }
        .task(id: feedback.toast) {
            guard feedback.toast != nil else { return }
            try? await Task.sleep(for: TTToast.lifetime)
            if !Task.isCancelled { feedback.toast = nil }
        }
    }
}
