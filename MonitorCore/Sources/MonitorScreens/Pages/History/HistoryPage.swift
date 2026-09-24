import AppKit
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI
import UniformTypeIdentifiers

/// DESIGN §3.13 History: timeline card (events row, 6 lanes with bands and a shared scrub cursor, axis, scrubber),
/// then the "At" card (time, top process, note, Export CSV · the time-travel treemap). Range from the header
/// (`nav.historyRange`, default 24H); Live pins the cursor to now.
///
/// Invalidation (ARCHITECTURE §7): the page body reads neither the live clock nor the cursor. Live ticks are fed by
/// `HistoryLiveFeed` (only on Live); the cursor line, lane values, scrubber and "At" readouts are small subviews, so
/// a scrub or tick doesn't rebuild lanes or re-run the band/chip layout (cached in the model by events/window/width).
public struct HistoryPage: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var provider
    @Environment(\.now) private var fixedNow
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.historyPersistent) private var historyPersistent
    @Environment(\.historyModelSeed) private var seed
    @Environment(\.historyExportDestination) private var exportDestination
    @State private var model: HistoryModel?

    public init() {}

    public var body: some View {
        VStack(spacing: TTSpace.gridGap) {
            if let banner = HistoryText.persistenceBanner(persistent: historyPersistent) {
                TTAlertBanner(title: "History isn’t being saved", message: banner, level: .elevated, actions: [])
                    .padding(.horizontal, -6)
            }
            if let model {
                HistoryTimelineCard(model: model)
                HistoryAtCard(model: model, onExport: { export(model) }, onSelectApp: { nav.inspect($0) })
                    .frame(maxHeight: .infinity)
            }
        }
        .background {
            // Zero-size observers: the page body itself reads neither the cursor nor the model's window.
            if let model {
                HistoryScrubPublisher(model: model)
                if nav.historyRange == .live { HistoryLiveFeed(model: model) }
            }
        }
        .padding(TTSpace.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageHeader(subtitle: HistoryText.subtitle(nav.historyRange))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model?.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model?.step(1); return .handled }
        .onAppear(perform: configure)
        .onChange(of: nav.historyRange) { _, new in select(new, restoring: nil) }
        .onChange(of: timeZone) { recalendar() }
        .onChange(of: locale) { recalendar() }
    }

    /// The page's one calendar (environment time zone + locale); everything reads `model.calendar`.
    private func pageCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = locale
        return cal
    }

    /// Time zone / locale changed: rebuild the calendar and the window in it (the cursor goes to the latest bucket).
    private func recalendar() {
        guard let model else { return }
        let cal = pageCalendar()
        guard cal != model.calendar else { return }
        model.calendar = cal
        select(nav.historyRange, restoring: nil)
    }

    /// The clock for (re)building windows — read in actions only, never in `body`.
    private func currentNow() -> Date { fixedNow ?? live.lastUpdate ?? Date() }

    private func configure() {
        guard model == nil else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if let seed {
                model = seed                                                // tests: pre-loaded
                return
            }
            model = HistoryModel(range: nav.historyRange, now: currentNow(), provider: provider,
                                 calendar: pageCalendar())
            select(nav.historyRange, restoring: nav.historyScrub)          // restore only on the first appear
        }
    }

    private func select(_ range: HistoryRange, restoring: Date?) {
        guard let model else { return }
        model.select(range, now: currentNow(), restoring: restoring)
        if range != .live { model.startLoading() }
    }

    private func export(_ model: HistoryModel) {
        let destination = exportDestination
        Task { await model.export(to: destination) }
    }
}

extension EnvironmentValues {
    /// Tests/snapshots: a pre-loaded model (the page then skips its own select/load).
    @Entry var historyModelSeed: HistoryModel? = nil
    /// Export CSV destination (default: `NSSavePanel` sheet on the key/dashboard window).
    @Entry var historyExportDestination: any HistoryExportDestination = SavePanelExportDestination()
}

/// Default Export CSV destination: an `NSSavePanel` run as a sheet on the dashboard window (modal if none).
public struct SavePanelExportDestination: HistoryExportDestination {
    public init() {}

    public func chooseDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }
}

/// Mirrors the cursor into `nav.historyScrub` (restored on the next first appear).
private struct HistoryScrubPublisher: View {
    let model: HistoryModel
    @Environment(NavigationModel.self) private var nav

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.cursor, initial: true) { publish() }
            .onChange(of: model.window) { publish() }
    }

    private func publish() {
        let value = model.isAtLatest ? nil : model.cursorTime
        if nav.historyScrub != value { nav.historyScrub = value }
    }
}

/// Feeds Live ticks (only mounted on the Live range, so the page body never depends on the clock).
private struct HistoryLiveFeed: View {
    let model: HistoryModel
    @Environment(LiveModel.self) private var live

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: live.lastUpdate, initial: true) { tick() }
    }

    private func tick() {
        guard let t = live.lastUpdate else { return }
        var series: [HistoryMetric: [SeriesPoint]] = [:]
        for m in HistoryModel.seriesMetrics { series[m] = live.series(m) }
        // Live follows the ring buffers' own clock (the newest sample), even with a pinned `now` in snapshots.
        model.applyLive(series: series, now: t, apps: live.apps)
    }
}

// MARK: - Timeline card

private enum TimelineMetrics {
    static let labelWidth: CGFloat = 170
    static let eventsHeight: CGFloat = 30
    static let laneHeight: CGFloat = 58
    static var chartHeight: CGFloat { eventsHeight + 6 * laneHeight }
}

private struct HistoryTimelineCard: View {
    let model: HistoryModel

    var body: some View {
        let window = model.window
        TTCard(spacing: TTSpace.x10) {
            HStack(spacing: TTSpace.x8) {
                Text(HistoryText.title(window, now: window.time(at: window.latest), calendar: model.calendar))
                    .font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HistoryLegend(model: model)
            }
            .frame(minHeight: 20)
            if case .failed(let error) = model.loadState {
                TTErrorState("History is unavailable.", detail: error)
                    .frame(height: TimelineMetrics.chartHeight)
            } else {
                HStack(alignment: .top, spacing: TTSpace.x8) {
                    HistoryLabelColumn(model: model)
                    HistoryChartColumn(model: model)
                }
            }
            HistoryAxis(window: window, calendar: model.calendar)
                .padding(.leading, TimelineMetrics.labelWidth + TTSpace.x8)
            VStack(alignment: .leading, spacing: TTSpace.x4) {
                Text("Scrub timeline").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                HistoryScrubber(model: model)
            }
            .padding(.leading, TimelineMetrics.labelWidth + TTSpace.x8)
        }
    }
}

/// Legend items only for band kinds present in the range.
private struct HistoryLegend: View {
    let model: HistoryModel

    var body: some View {
        let kinds = model.legendKinds
        if !kinds.isEmpty { TTLegend(items: kinds.map { ($0.legend, $0.swatch) }) }
    }
}

private struct HistoryLabelColumn: View {
    let model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Events").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .frame(height: TimelineMetrics.eventsHeight)
                .overlay(alignment: .bottom) { TTSeparator() }
            ForEach(HistoryLane.all) { lane in
                VStack(alignment: .leading, spacing: TTSpace.x2) {
                    HStack(spacing: TTSpace.x7) {
                        TTIcon(lane.icon, size: 14)
                        Text(lane.label).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                    }
                    HistoryLaneValue(model: model, metric: lane.metric)
                        .padding(.leading, TTSpace.x21)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .frame(height: TimelineMetrics.laneHeight)
                .overlay(alignment: .bottom) { TTSeparator() }
            }
        }
        .frame(width: TimelineMetrics.labelWidth)
    }
}

/// The value at the cursor (re-evaluated on scrub; nothing else is).
private struct HistoryLaneValue: View {
    let model: HistoryModel
    let metric: HistoryMetric
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units

    var body: some View {
        let values = model.lanes[metric]
        let value = values.flatMap { $0.indices.contains(model.cursor) ? $0[model.cursor] : nil }
        MetricValue(HistoryText.laneValue(metric, value, units: units),
                    unavailableReason: value == nil ? unavailableReason(metric, health: live.sensorHealth) : nil,
                    font: TTFont.pageTitle)
            .foregroundStyle(TTColor.textPrimary)
    }
}

/// Events row + lanes + bands + cursor; drag anywhere on the lanes to scrub.
private struct HistoryChartColumn: View {
    let model: HistoryModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: TimelineMetrics.eventsHeight)
                        .overlay(alignment: .bottom) { TTSeparator() }
                    HistoryLanes(model: model)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in model.scrub(to: Self.index(g.location.x, width: w, window: model.window)) }
                            .onEnded { _ in model.endScrub() })
                }
                HistoryBandsLayer(model: model, width: w)
                HistoryNoDataLayer(model: model, width: w)
                HistoryChipsLayer(model: model, width: w)
                HistoryCursor(model: model, width: w)
            }
        }
        .frame(height: TimelineMetrics.chartHeight)
    }

    static func index(_ x: CGFloat, width: CGFloat, window: HistoryWindow) -> Int {
        guard width > 0 else { return window.latest }
        return window.clamp(Int((x / width * CGFloat(window.count - 1)).rounded()))
    }
}

/// Lane sparklines; rebuilt only when the series or window change (not on scrub).
private struct HistoryLanes: View {
    let model: HistoryModel

    var body: some View {
        let window = model.window
        VStack(spacing: 0) {
            ForEach(HistoryLane.all) { lane in
                let values = model.lanes[lane.metric] ?? []
                let points = values.enumerated().map { SeriesPoint(time: window.time(at: $0.offset), value: $0.element) }
                TTAreaChart(points, color: lane.color, yDomain: lane.domain(values), fillOpacity: TTChartFill.sparkline,
                            lineWidth: TTStroke.sparkThin, showsCollecting: window.range == .live)
                    .frame(height: 48)
                    .padding(.bottom, 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .frame(height: TimelineMetrics.laneHeight)
                    .overlay(alignment: .bottom) { TTSeparator() }
            }
        }
    }
}

private struct HistoryBandsLayer: View {
    let model: HistoryModel
    let width: CGFloat

    var body: some View {
        let lanesHeight = TimelineMetrics.chartHeight - TimelineMetrics.eventsHeight
        ForEach(Array(model.bands(width: width).enumerated()), id: \.offset) { _, band in
            Rectangle().fill(band.kind.fill)
                .frame(width: band.x1 - band.x0, height: lanesHeight)
                .overlay {
                    if band.kind == .paused && band.x1 - band.x0 >= 40 {
                        Text("Paused").font(TTFont.micro).foregroundStyle(TTColor.textTertiary)
                    }
                }
                .offset(x: band.x0, y: TimelineMetrics.eventsHeight)
                .allowsHitTesting(false)
        }
    }
}

/// DESIGN §3.15 partial history: `fillTrack` over [window start, first stored sample), "No data yet" if ≥ 60 wide.
private struct HistoryNoDataLayer: View {
    let model: HistoryModel
    let width: CGFloat

    var body: some View {
        if let until = model.noDataUntil {
            let x1 = CGFloat(model.window.fraction(of: until)) * width
            if x1 > 0.5 {
                Rectangle().fill(TTColor.fillTrack)
                    .frame(width: x1, height: TimelineMetrics.chartHeight - TimelineMetrics.eventsHeight)
                    .overlay {
                        if x1 >= 60 { Text("No data yet").font(TTFont.micro).foregroundStyle(TTColor.textTertiary) }
                    }
                    .offset(y: TimelineMetrics.eventsHeight)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct HistoryChipsLayer: View {
    let model: HistoryModel
    let width: CGFloat
    private static let font = NSFont.systemFont(ofSize: 11)

    var body: some View {
        let chips = model.chips(width: width,
                                measure: { ($0 as NSString).size(withAttributes: [.font: Self.font]).width })
        ForEach(chips) { chip in
            HStack(spacing: TTSpace.x4) {
                Button { model.jump(to: chip.event) } label: {
                    Text(chip.text).monospacedDigit()
                }
                .buttonStyle(.tt(.chip))
                .help(chip.text)
                if chip.hidden > 0 {
                    Text("+\(chip.hidden)")
                        .font(TTFont.caption).foregroundStyle(TTColor.textPrimary)
                        .padding(.horizontal, TTSpace.x8)
                        .frame(height: HistoryChip.height)
                        .background(Capsule().fill(TTColor.bgElevated))
                        .overlay(Capsule().strokeBorder(TTColor.borderPopover, lineWidth: TTStroke.hairline))
                }
            }
            .fixedSize()
            // The layout already settled the groups as a sequence inside the width (HistoryChip.settle).
            .position(x: chip.left + chip.groupWidth / 2, y: TTSpace.x4 + HistoryChip.height / 2)
        }
    }
}

/// Cursor: full height, 1.5 wide, `textPrimary` @ 0.85.
private struct HistoryCursor: View {
    let model: HistoryModel
    let width: CGFloat

    var body: some View {
        let window = model.window
        let x = CGFloat(window.count > 1 ? Double(model.cursor) / Double(window.count - 1) : 1) * width
        Rectangle().fill(TTColor.textPrimary.opacity(TTOpacity.cursor))
            .frame(width: TTStroke.cursor, height: TimelineMetrics.chartHeight)
            .offset(x: x - TTStroke.cursor / 2)
            .allowsHitTesting(false)
    }
}

/// Stored ranges: labels at `window.fraction` of their moments (day starts on 7D/30D); Live/1H: relative axis.
private struct HistoryAxis: View {
    let window: HistoryWindow
    let calendar: Calendar

    var body: some View {
        if let labels = HistoryText.axisLabels(window, calendar: calendar) {
            GeometryReader { geo in
                ForEach(labels.indices, id: \.self) { i in
                    let label = labels[i]
                    Text(label.text).font(TTFont.micro).foregroundStyle(TTColor.textTertiary).lineLimit(1).fixedSize()
                        .monospacedDigit()
                        .alignmentGuide(.leading) { d in
                            // First label leads at 0, last trails at the edge, others centre on their moment.
                            let x = CGFloat(label.fraction) * geo.size.width
                            if label.fraction <= 0 { return 0 }
                            if label.fraction >= 1 { return d.width - geo.size.width }
                            return d.width / 2 - x
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 12)
        } else {
            TTTimeAxis(range: window.range, end: window.time(at: window.latest))
        }
    }
}

/// Scrubber (ruling: custom, not `NSSlider`, so it renders the reference in any window state): 8-pt capsule track,
/// `accent` fill to the knob, light rest track with a hairline edge, 16-pt `accent` knob (reference crop).
/// Drag to scrub; ←/→ step at the page; VoiceOver adjustable.
private struct HistoryScrubber: View {
    let model: HistoryModel

    static let trackHeight: CGFloat = 8
    static let knob: CGFloat = 16
    static let rest = TTColor.scrubberRest
    static let restEdge = TTColor.scrubberRestEdge

    var body: some View {
        let window = model.window
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(w - Self.knob, 1)
            let f = window.count > 1 ? CGFloat(model.cursor) / CGFloat(window.count - 1) : 1
            let x = Self.knob / 2 + f * span
            ZStack(alignment: .leading) {
                Capsule().fill(Self.rest)
                    .overlay(Capsule().strokeBorder(Self.restEdge, lineWidth: 0.5))
                    .frame(height: Self.trackHeight)
                Capsule().fill(TTColor.accent)
                    .frame(width: max(x, Self.trackHeight), height: Self.trackHeight)
                Circle().fill(TTColor.accent)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: x - Self.knob / 2)
            }
            .frame(height: Self.knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let i = Int(((g.location.x - Self.knob / 2) / span * CGFloat(window.count - 1)).rounded())
                    model.scrub(to: i)
                }
                .onEnded { _ in model.endScrub() })
        }
        .frame(height: Self.knob)
        .accessibilityElement()
        .accessibilityLabel("Scrub timeline")
        .accessibilityValue(model.cursorLabel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.step(1)
            case .decrement: model.step(-1)
            @unknown default: break
            }
        }
    }
}

// MARK: - "At" card

private struct HistoryAtCard: View {
    let model: HistoryModel
    let onExport: () -> Void
    let onSelectApp: (AppKey) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: TTSpace.x24) {
            VStack(alignment: .leading, spacing: TTSpace.x10) {
                HistoryAtReadout(model: model)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: TTSpace.x6) {
                    Button("Export CSV", action: onExport)
                        .buttonStyle(.tt(.regularSecondary))
                        .help("Save the system totals of this range as CSV")
                    HistoryExportStatusLine(model: model)
                }
            }
            .frame(width: 220, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            HistoryTreemapPanel(model: model, onSelectApp: onSelectApp)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, TTSpace.x14 + TTStroke.hairline)
        .padding(.horizontal, TTSpace.x16 + TTStroke.hairline)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ttCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// At time / top process / note (re-evaluated on scrub and share changes only).
private struct HistoryAtReadout: View {
    let model: HistoryModel
    @Environment(\.unitPreferences) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.x10) {
            VStack(alignment: .leading, spacing: TTSpace.x2) {
                Text("At").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                if model.isAtLatest {
                    HStack(spacing: TTSpace.x8) {
                        Text("Now").font(TTFont.title2).foregroundStyle(TTColor.textPrimary)
                        if model.showsLiveBadge { TTBadge("Live", level: .calm) }
                    }
                } else {
                    Text(model.cursorLabel)
                        .font(TTFont.title2).foregroundStyle(TTColor.textPrimary).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: TTSpace.x2) {
                Text("Top process").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                MetricValue(HistoryText.topProcess(model.topShare, metric: model.metric, units: units),
                            unavailableReason: "No data for this moment", font: TTFont.dialogTitle)
                    .foregroundStyle(TTColor.textPrimary)
            }
            Text(model.note(units: units))
                .font(TTFont.body12Para).lineSpacing(TTFont.body12ParaSpacing)
                .foregroundStyle(TTColor.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Inline Export CSV result ("Exported 288 rows" / "Export failed: …").
private struct HistoryExportStatusLine: View {
    let model: HistoryModel

    var body: some View {
        if let status = model.exportStatus {
            Text(status.text)
                .font(TTFont.caption)
                .foregroundStyle(status.isFailure ? TTColor.statusCritical : TTColor.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension HistoryExportStatus {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

private struct HistoryTreemapPanel: View {
    let model: HistoryModel
    let onSelectApp: (AppKey) -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: TTSpace.x8) {
            HStack(spacing: TTSpace.x8) {
                Text("App share").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TTSegmented(selection: $model.metric, options: TreemapMetric.allCases.map { ($0, $0.title) },
                            compact: true)
                    .accessibilityLabel("App share metric")
            }
            .frame(height: 24)
            TTTreemap(model.shares, metric: model.metric.treemapMetric,
                      animated: !isSnapshot && !model.isScrubbing, otherCount: model.otherCount,
                      onSelect: onSelectApp)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
