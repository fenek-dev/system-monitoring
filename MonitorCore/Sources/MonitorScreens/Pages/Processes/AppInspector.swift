import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.12 inspector card. Collapsed (~78 tall): tile 44 · identity (300) · 4 stats · [Quit] [Force Quit…]
/// [⋯] [chevron]. Expanded (min 391, `.easeInOut(0.2)`): separator (16 above/below) and a 2-column body (min 280):
/// "Activity" lanes with a compact range control, and "Live connections". No "Sample" button (ruling).
struct AppInspector: View {
    let row: ProcessRow?
    let availability: ProcessActionAvailability
    let detailExpanded: Bool
    let onToggleDetail: () -> Void
    let onQuit: (ProcessTarget) -> Void
    let onForceQuit: (ProcessTarget) -> Void
    let model: AppInspectorModel

    static let collapsedHeight: CGFloat = 78
    static let expandedMinHeight: CGFloat = 391

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row {
                header(row)
                if detailExpanded {
                    TTSeparator().padding(.vertical, TTSpace.x16)
                    AppDetailBody(row: row, model: model)
                        .frame(minHeight: 280, alignment: .top)
                        .transition(.opacity)
                }
            } else {
                Text("Select a row to inspect")
                    .font(TTFont.body12)
                    .foregroundStyle(TTColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(TTSpace.cardPadding + TTStroke.hairline)
        .frame(maxWidth: .infinity, minHeight: row != nil && detailExpanded ? Self.expandedMinHeight : Self.collapsedHeight,
               alignment: .topLeading)
        .ttCardBackground()
    }

    private func header(_ row: ProcessRow) -> some View {
        HStack(spacing: TTSpace.x20) {
            TTAppTile(identity: row.identity, name: row.name, size: 44)
            VStack(alignment: .leading, spacing: TTSpace.x3) {
                Text(row.name).font(TTFont.pageTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                Text(row.path ?? "—")
                    .font(TTFont.mono11).foregroundStyle(TTColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(row.path ?? "")
                Text(Self.meta(row))
                    .font(TTFont.caption).foregroundStyle(TTColor.textTertiary).monospacedDigit().lineLimit(1)
            }
            .frame(width: 300, alignment: .leading)
            HStack(alignment: .top, spacing: TTSpace.x16) {
                stat("CPU", TTFormat.cpuPercent(row.cpu), .cpu, row, estimated: row.cpuEstimated)
                stat("GPU", TTFormat.cpuPercent(row.gpu), .gpu, row)
                stat("Memory", TTFormat.bytes(row.memory), .memory, row)
                stat("Energy", TTFormat.appWatts(row.energy), .energy, row, estimated: row.energyEstimated)
            }
            .frame(maxWidth: .infinity)
            buttons(row)
        }
        .frame(minHeight: 44)
    }

    /// "PID 2210 · arthur · 64 threads"; groups "PID {responsible} · {user} · {n} processes".
    static func meta(_ row: ProcessRow) -> String {
        var parts: [String] = []
        parts.append("PID \(row.pid.map { String($0) } ?? "—")")
        if let user = row.user { parts.append(user) }
        if row.rowKind == .app && row.processCount > 1 {
            parts.append("\(row.processCount.formatted()) processes")
        } else if let t = row.threads {
            parts.append("\(Int(t).formatted()) \(t == 1 ? "thread" : "threads")")
        }
        return parts.joined(separator: " · ")
    }

    private func stat(_ label: String, _ text: String, _ column: ProcessColumn, _ row: ProcessRow,
                      estimated: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: TTSpace.x2) {
            Text(label).font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
            MetricValue(row.value(column) == nil ? nil : text, unavailableReason: row.reasons[column],
                        estimated: estimated, font: TTFont.pageTitle)
                .foregroundStyle(TTColor.textPrimary)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(_ row: ProcessRow) -> some View {
        HStack(spacing: TTSpace.x8) {
            Button("Quit") { if let t = row.target { onQuit(t) } }
                .buttonStyle(.tt(.regularSecondary))
                .disabled(!availability.canQuit)
                .help(availability.disabledHelp ?? "Quit \(row.name)")
            Button("Force Quit…") { if let t = row.target { onForceQuit(t) } }
                .buttonStyle(.tt(.regularDestructive))
                .disabled(!availability.canForceQuit)
                .help(availability.disabledHelp ?? "Force quit \(row.name)")
            InspectorMenuButton(target: row.target, name: row.name)
            TTIconButton(detailExpanded ? .chevronDown : .chevronRight,
                         label: detailExpanded ? "Hide details" : "Show details", variant: .header) {
                onToggleDetail()
            }
        }
        .fixedSize()
    }
}

/// `iconButton` 28 `ellipsis` opening the row actions menu (DESIGN §2.25).
private struct InspectorMenuButton: View {
    let target: ProcessTarget?
    let name: String
    @State private var hovering = false

    var body: some View {
        Menu {
            if let target { TTRowActionsMenu(target: target) }
        } label: {
            TTIcon(.ellipsis, size: 16, color: TTColor.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
                    .fill(hovering ? TTColor.fillIconButton : .clear))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(target == nil)
        .onHover { hovering = $0 }
        .help("Actions for \(name)")
        .accessibilityLabel("Actions for \(name)")
    }
}

/// Expanded body: grid 2 × 1fr, gap 24.
private struct AppDetailBody: View {
    let row: ProcessRow
    let model: AppInspectorModel
    @Environment(LiveModel.self) private var live
    @Environment(\.historyProvider) private var provider
    @Environment(\.unitPreferences) private var units
    @Environment(\.now) private var fixedNow

    var body: some View {
        @Bindable var model = model
        let end = fixedNow ?? live.lastUpdate ?? Date()
        HStack(alignment: .top, spacing: TTSpace.x24) {
            VStack(alignment: .leading, spacing: TTSpace.x10) {
                HStack(spacing: TTSpace.x8) {
                    Text("Activity").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TTSegmented(selection: $model.range, options: HistoryRange.allCases.map { ($0, $0.label) },
                                compact: true)
                        .accessibilityLabel("Activity range")
                }
                .frame(height: 24)
                GeometryReader { geo in
                    // The sparkline fills the width (DESIGN §2.5 App detail); the value keeps a 72-pt column.
                    let chart = max(40, geo.size.width - 84 - 2 * TTSpace.x12 - Self.valueWidth)
                    VStack(spacing: TTSpace.x4) {
                        ForEach(InspectorLane.allCases, id: \.self) { lane in
                            let pts = model.points(lane, row: row, live: live)
                            TTTimelineRow(label: lane.label, icon: lane.icon, value: lane.valueText(row, units: units),
                                          unavailableReason: row.reasons[lane.column], points: pts,
                                          color: lane.color, yDomain: lane.domain(pts), chartWidth: chart, height: 34)
                        }
                    }
                }
                .frame(height: 6 * 34 + 5 * TTSpace.x4)
                TTTimeAxis(range: model.range, end: end)
                    .padding(.leading, 96)
                    .padding(.trailing, Self.valueWidth + TTSpace.x12)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .task(id: AppInspectorModel.StoredKey(app: row.appKey, range: model.range,
                                                  end: Self.bucketEnd(end, range: model.range))) {
                await model.load(app: row.appKey, range: model.range,
                                 end: Self.bucketEnd(end, range: model.range), provider: provider)
            }
            ConnectionsPanel(row: row, connections: AppInspectorModel.connections(live.connections, for: row))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    static let valueWidth: CGFloat = 72

    /// Stored ranges reload once per display bucket, not per second.
    static func bucketEnd(_ end: Date, range: HistoryRange) -> Date {
        let step = Double(range.displayBucket.components.seconds)
        guard step > 0 else { return end }
        return Date(timeIntervalSince1970: (end.timeIntervalSince1970 / step).rounded(.up) * step)
    }
}

/// "Live connections · N": `minmax(0,1fr) 52 48 72 72`, header 26, rows 28, scrolls past 7 rows.
private struct ConnectionsPanel: View {
    let row: ProcessRow
    let connections: [ConnectionSample]
    @Environment(\.unitPreferences) private var units
    @Environment(\.isSnapshot) private var isSnapshot

    static let widths: [CGFloat] = [52, 48, 72, 72]

    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.x10) {
            Text(connections.isEmpty ? "Live connections" : "Live connections · \(connections.count.formatted())")
                .font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).monospacedDigit()
                .frame(height: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                header
                if row.target == nil && row.rowKind == .process && row.pid == nil {
                    empty("Not running")
                } else if connections.isEmpty {
                    empty("No open connections")
                } else if isSnapshot {
                    VStack(spacing: 0) { rows }.padding(.top, TTSpace.x4)
                        .frame(maxHeight: 7 * 28 + 4, alignment: .top).clipped()
                } else {
                    ScrollView { LazyVStack(spacing: 0) { rows }.padding(.top, TTSpace.x4) }
                        .frame(maxHeight: 7 * 28 + 4)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: TTSpace.tableCellGap) {
            Text("Remote host").frame(maxWidth: .infinity, alignment: .leading)
            Text("Port").frame(width: Self.widths[0], alignment: .trailing)
            Text("Proto").frame(width: Self.widths[1], alignment: .leading)
            Text("↓").frame(width: Self.widths[2], alignment: .trailing)
            Text("↑").frame(width: Self.widths[3], alignment: .trailing)
        }
        .font(TTFont.captionMedium).foregroundStyle(TTColor.textSecondary).lineLimit(1)
        .padding(.horizontal, TTSpace.tableRowInset)
        .frame(height: 26)
        .overlay(alignment: .bottom) { TTSeparator() }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
            .frame(maxWidth: .infinity).frame(height: 80)
    }

    @ViewBuilder private var rows: some View {
        ForEach(Array(connections.enumerated()), id: \.element.id) { i, c in
            HStack(spacing: TTSpace.tableCellGap) {
                Group {
                    if let host = c.remoteHost {
                        Text(host).font(TTFont.body12)
                    } else {
                        Text(c.remoteAddress ?? "—").font(TTFont.mono11)
                    }
                }
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(c.remoteHost ?? c.remoteAddress ?? "")
                MetricValue(c.remotePort.map { String($0) }, font: TTFont.body12)
                    .frame(width: Self.widths[0], alignment: .trailing)
                Text(Self.proto(c.proto)).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                    .frame(width: Self.widths[1], alignment: .leading)
                MetricValue(c.rxBps == nil ? nil : TTFormat.rateCell(c.rxBps, units: units), font: TTFont.body12)
                    .frame(width: Self.widths[2], alignment: .trailing)
                MetricValue(c.txBps == nil ? nil : TTFormat.rateCell(c.txBps, units: units), font: TTFont.body12)
                    .frame(width: Self.widths[3], alignment: .trailing)
            }
            .foregroundStyle(TTColor.textPrimary)
            .padding(.horizontal, TTSpace.tableRowInset)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
                .fill(i % 2 == 1 ? TTColor.fillZebra : .clear))
        }
    }

    static func proto(_ p: TransportProtocol) -> String {
        switch p {
        case .tcp: "TCP"
        case .udp, .quic: "UDP"
        case .other: "—"
        }
    }
}
