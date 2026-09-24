import AppKit
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI
import UniformTypeIdentifiers

/// DESIGN §3.13 History: timeline card (events row, 6 lanes with bands and a shared scrub cursor, axis, slider),
/// then the "At" card (time, top process, note, Export CSV · the time-travel treemap). Range from the header
/// (`nav.historyRange`, default 24H); Live pins the cursor to now.
public struct HistoryPage: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.historyProvider) private var provider
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.now) private var fixedNow
    @Environment(\.timeZone) private var timeZone
    @State private var model = HistoryModel(provider: EmptyHistoryProvider())
    @State private var configured = false

    public init() {}

    private var now: Date { fixedNow ?? live.lastUpdate ?? Date() }

    public var body: some View {
        VStack(spacing: TTSpace.gridGap) {
            HistoryTimelineCard(model: model, now: now)
            HistoryAtCard(model: model, now: now, onExport: export, onSelectApp: openApp)
                .frame(maxHeight: .infinity)
        }
        .padding(TTSpace.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageHeader(subtitle: HistoryText.subtitle(nav.historyRange))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
        .onAppear(perform: configure)
        .onChange(of: nav.historyRange) { _, new in select(new) }
        .onChange(of: live.lastUpdate) { tickLive() }
        .onChange(of: model.cursor) { publishScrub() }
        .onChange(of: model.metric) { if isSnapshot { model.loadSynchronously() } }
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        model.calendar = cal
        model.provider = provider
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { select(nav.historyRange) }
    }

    private func select(_ range: HistoryRange) {
        model.select(range, now: now)
        if let t = nav.historyScrub { model.restoreCursor(to: t) }
        if range == .live {
            tickLive()
        } else if isSnapshot {
            model.loadSynchronously()
        } else {
            model.startLoading()
        }
        publishScrub()
    }

    private func tickLive() {
        guard model.range == .live, let t = live.lastUpdate ?? fixedNow else { return }
        var series: [HistoryMetric: [SeriesPoint]] = [:]
        for m in HistoryModel.laneMetrics { series[m] = live.series(m) }
        // Live follows the ring buffers' own clock (the newest sample), even with a pinned `now` in snapshots.
        model.applyLive(series: series, now: t, apps: live.apps)
    }

    private func publishScrub() {
        nav.historyScrub = model.isAtLatest ? nil : model.cursorTime
    }

    /// Treemap click: Processes with the app selected and its detail expanded (DESIGN §2.28).
    private func openApp(_ key: AppKey) {
        nav.inspect(key)
    }

    private func export() {
        let range = model.range
        Task {
            await model.export {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "Telltale History \(range.label).csv"
                return panel.runModal() == .OK ? panel.url : nil
            }
        }
    }
}

// MARK: - Timeline card

private struct HistoryTimelineCard: View {
    let model: HistoryModel
    let now: Date
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.historyPersistent) private var historyPersistent

    static let labelWidth: CGFloat = 170
    static let eventsHeight: CGFloat = 30
    static let laneHeight: CGFloat = 58

    var body: some View {
        let window = model.window
        TTCard(spacing: TTSpace.x10) {
            HStack(spacing: TTSpace.x8) {
                Text(HistoryText.title(window, now: now, locale: locale, timeZone: timeZone))
                    .font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let kinds = legendKinds(window)
                if !kinds.isEmpty {
                    TTLegend(items: kinds.map { ($0.legend, $0.swatch) })
                }
            }
            .frame(minHeight: 20)
            if let error = storeError {
                TTErrorState("History is unavailable.", detail: error)
                    .frame(height: Self.eventsHeight + 6 * Self.laneHeight)
            } else {
                HStack(alignment: .top, spacing: TTSpace.x8) {
                    labelColumn
                    HistoryChartColumn(model: model, now: now)
                }
            }
            TTTimeAxis(range: window.range, end: now, style: window.range == .day ? .clock : .relative)
                .padding(.leading, Self.labelWidth + TTSpace.x8)
            VStack(alignment: .leading, spacing: TTSpace.x4) {
                Text("Scrub timeline").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                HistoryScrubber(model: model)
            }
            .padding(.leading, Self.labelWidth + TTSpace.x8)
        }
    }

    /// DESIGN §3.15 "Store error" / ARCHITECTURE §6: a failed query, or a store that could not be opened
    /// (`historyPersistent == false`, in-memory fallback) on the stored ranges. Live still draws from the ring.
    private var storeError: String? {
        if case .failed(let error) = model.loadState { return error }
        if !historyPersistent && model.range != .live {
            return "The history database could not be opened; nothing is kept after Telltale quits."
        }
        return nil
    }

    private func legendKinds(_ window: HistoryWindow) -> [HistoryBandKind] {
        let present = Set(HistoryBand.layout(model.events, window: window, width: 100, now: now).map(\.kind))
        return HistoryBandKind.allCases.filter(present.contains)
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Events").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .frame(height: Self.eventsHeight)
                .overlay(alignment: .bottom) { TTSeparator() }
            ForEach(HistoryLane.all) { lane in
                let value = model.lanes[lane.metric].flatMap { $0.indices.contains(model.cursor) ? $0[model.cursor] : nil }
                VStack(alignment: .leading, spacing: TTSpace.x2) {
                    HStack(spacing: TTSpace.x7) {
                        TTIcon(lane.icon, size: 14)
                        Text(lane.label).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                    }
                    MetricValue(HistoryText.laneValue(lane.metric, value, units: units),
                                unavailableReason: value == nil ? unavailableReason(lane.metric, health: live.sensorHealth)
                                    : nil,
                                font: TTFont.pageTitle)
                        .foregroundStyle(TTColor.textPrimary)
                        .padding(.leading, TTSpace.x21)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .frame(height: Self.laneHeight)
                .overlay(alignment: .bottom) { TTSeparator() }
            }
        }
        .frame(width: Self.labelWidth)
    }
}

/// Events row + lanes + bands + cursor; drag anywhere on the lanes to scrub.
private struct HistoryChartColumn: View {
    let model: HistoryModel
    let now: Date
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let window = model.window
        let height = HistoryTimelineCard.eventsHeight + 6 * HistoryTimelineCard.laneHeight
        GeometryReader { geo in
            let w = geo.size.width
            let lanesHeight = height - HistoryTimelineCard.eventsHeight
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: HistoryTimelineCard.eventsHeight)
                        .overlay(alignment: .bottom) { TTSeparator() }
                    lanes(window)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in model.scrub(to: index(g.location.x, width: w, window: window)) }
                            .onEnded { _ in model.endScrub() })
                }
                ForEach(Array(HistoryBand.layout(model.events, window: window, width: w, now: now).enumerated()),
                        id: \.offset) { _, band in
                    Rectangle().fill(band.kind.fill)
                        .frame(width: band.x1 - band.x0, height: lanesHeight)
                        .overlay {
                            if band.kind == .paused && band.x1 - band.x0 >= 40 {
                                Text("Paused").font(TTFont.micro).foregroundStyle(TTColor.textTertiary)
                            }
                        }
                        .offset(x: band.x0, y: HistoryTimelineCard.eventsHeight)
                        .allowsHitTesting(false)
                }
                partialHistory(window, width: w, lanesHeight: lanesHeight)
                chips(window, width: w)
                let x = CGFloat(window.count > 1 ? Double(model.cursor) / Double(window.count - 1) : 1) * w
                Rectangle().fill(TTColor.textPrimary.opacity(TTOpacity.cursor))
                    .frame(width: TTStroke.cursor, height: height)
                    .offset(x: x - TTStroke.cursor / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
    }

    private func index(_ x: CGFloat, width: CGFloat, window: HistoryWindow) -> Int {
        guard width > 0 else { return window.latest }
        return window.clamp(Int((x / width * CGFloat(window.count - 1)).rounded()))
    }

    private func lanes(_ window: HistoryWindow) -> some View {
        VStack(spacing: 0) {
            ForEach(HistoryLane.all) { lane in
                let values = model.lanes[lane.metric] ?? []
                let points = values.enumerated().map { SeriesPoint(time: window.time(at: $0.offset), value: $0.element) }
                TTAreaChart(points, color: lane.color, yDomain: lane.domain(values), fillOpacity: TTChartFill.sparkline,
                            lineWidth: TTStroke.sparkThin, showsCollecting: window.range == .live)
                    .frame(height: 48)
                    .padding(.bottom, 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .frame(height: HistoryTimelineCard.laneHeight)
                    .overlay(alignment: .bottom) { TTSeparator() }
            }
        }
    }

    /// DESIGN §3.15 partial history: `fillTrack` before the first stored sample, "No data yet" if ≥ 60 wide.
    @ViewBuilder
    private func partialHistory(_ window: HistoryWindow, width: CGFloat, lanesHeight: CGFloat) -> some View {
        if window.range != .live, model.loadState == .loaded, model.coverageKnown {
            let x1: CGFloat = model.coverage.map { CGFloat(window.fraction(of: $0.start)) * width } ?? width
            if x1 > 0.5 {
                Rectangle().fill(TTColor.fillTrack)
                    .frame(width: x1, height: lanesHeight)
                    .overlay {
                        if x1 >= 60 {
                            Text("No data yet").font(TTFont.micro).foregroundStyle(TTColor.textTertiary)
                        }
                    }
                    .offset(y: HistoryTimelineCard.eventsHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Center of chip + "+n" kept inside the chart width.
    static func groupCenter(_ chip: HistoryChip, width: CGFloat) -> CGFloat {
        let extra = chip.hidden > 0 ? HistoryChip.plusWidth + TTSpace.x4 : 0
        let total = chip.width + extra
        return min(max(chip.x + extra / 2, total / 2), max(width - total / 2, total / 2))
    }

    private func chips(_ window: HistoryWindow, width: CGFloat) -> some View {
        let tz = timeZone
        let font = NSFont.systemFont(ofSize: 11)
        let chips = HistoryChip.layout(model.events, window: window, width: width,
                                       label: { HistoryText.chipLabel($0, timeZone: tz) },
                                       measure: { ($0 as NSString).size(withAttributes: [.font: font]).width })
        return ForEach(chips) { chip in
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
            .position(x: Self.groupCenter(chip, width: width), y: TTSpace.x4 + HistoryChip.height / 2)
        }
    }
}

/// `NSSlider`-backed scrubber, 0…count−1, integer steps, tinted `accent`.
private struct HistoryScrubber: View {
    let model: HistoryModel

    var body: some View {
        let window = model.window
        let binding = Binding<Double>(get: { Double(model.cursor) },
                                      set: { model.scrub(to: Int($0.rounded())) })
        // Continuous NSSlider (a `step` would draw 288 tick marks); the binding snaps to whole buckets.
        Slider(value: binding, in: 0...Double(max(window.count - 1, 1))) { editing in
            if !editing { model.endScrub() }
        }
        .labelsHidden()
        .controlSize(.small)
        .tint(TTColor.accent)
        .accessibilityLabel("Scrub timeline")
    }
}

// MARK: - "At" card

private struct HistoryAtCard: View {
    let model: HistoryModel
    let now: Date
    let onExport: () -> Void
    let onSelectApp: (AppKey) -> Void
    @Environment(\.unitPreferences) private var units
    @Environment(\.timeZone) private var timeZone
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: TTSpace.x24) {
            VStack(alignment: .leading, spacing: TTSpace.x10) {
                VStack(alignment: .leading, spacing: TTSpace.x2) {
                    Text("At").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                    if model.isAtLatest {
                        HStack(spacing: TTSpace.x8) {
                            Text("Now").font(TTFont.title2).foregroundStyle(TTColor.textPrimary)
                            if model.range == .live && model.pinned || model.range != .live {
                                TTBadge("Live", level: .calm)
                            }
                        }
                    } else {
                        Text(TTFormat.clock(model.cursorTime, timeZone: timeZone))
                            .font(TTFont.title2).foregroundStyle(TTColor.textPrimary).monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: TTSpace.x2) {
                    Text("Top process").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                    MetricValue(HistoryText.topProcess(model.topShare, metric: model.metric, units: units),
                                unavailableReason: "No data for this moment", font: TTFont.dialogTitle)
                        .foregroundStyle(TTColor.textPrimary)
                }
                Text(HistoryText.note(model.events, at: model.cursorTime, bucket: model.window.bucket, now: now))
                    .font(TTFont.body12Para).lineSpacing(TTFont.body12ParaSpacing)
                    .foregroundStyle(TTColor.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Export CSV", action: onExport)
                    .buttonStyle(.tt(.regularSecondary))
                    .help(model.exportStatus ?? "Save the system totals of this range as CSV")
            }
            .frame(width: 220, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
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
