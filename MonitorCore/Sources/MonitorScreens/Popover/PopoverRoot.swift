import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Menu bar popover content (DESIGN §3.1–3.2). `PopoverContainer` (W4) adds the 360-pt chrome and padding 6.
/// Top to bottom: header, alert banners, full rows, divider, compact rows, divider, top consumer, divider, footer.
/// Rows follow `PopoverLayout` (order, hidden); a divider is dropped when either side is empty.
public struct PopoverRoot: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.popoverLayout) private var layout
    @Environment(\.unitPreferences) private var units
    @Environment(\.appCommands) private var commands
    @Environment(\.processActions) private var actions
    @State private var expanded: Set<MonitorModel.Category>

    public init() { _expanded = State(initialValue: []) }

    /// Rows initially expanded (snapshots of the ADDED expansion).
    public init(expanded: Set<MonitorModel.Category>) { _expanded = State(initialValue: expanded) }

    public var body: some View {
        let sections = PopoverModel.sections(layout)
        let consumer = PopoverModel.consumer(live: live)
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader()
            ForEach(PopoverModel.banners(live: live, units: units, canControl: actions.canControl)) { banner in
                PopoverBannerView(banner: banner, perform: perform)
            }
            rows(sections.full)
            if !sections.full.isEmpty && !sections.compact.isEmpty { divider }
            rows(sections.compact)
            if !(sections.full.isEmpty && sections.compact.isEmpty) && consumer != nil { divider }
            if let consumer { TopConsumerView(consumer: consumer) }
            divider
            footer
        }
    }

    private func rows(_ categories: [MonitorModel.Category]) -> some View {
        ForEach(categories, id: \.self) { c in
            let open = expanded.contains(c)
            PopoverRowView(row: PopoverModel.row(c, live: live, units: units), expanded: open,
                           lines: open ? PopoverModel.expansion(c, live: live, units: units) : [],
                           toggle: { if open { expanded.remove(c) } else { expanded.insert(c) } },
                           openPage: { commands.openDashboard(c.dashboardPage) },
                           openApp: { commands.inspectApp($0) })
        }
    }

    /// 1 pt `separator`, margin 4 vertical, 10 horizontal.
    private var divider: some View {
        TTSeparator().padding(.vertical, 4).padding(.horizontal, 10)
    }

    /// HStack gap 8, padding 6 top, 4 horizontal, 4 bottom: Open Dashboard (flex), History, Quit Telltale (ADDED).
    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Dashboard") { commands.openDashboard(.overview) }
                .buttonStyle(TTButtonStyle(.popoverPrimary))
                .keyboardShortcut("d", modifiers: .command)
            Button("History") { commands.openDashboard(.history) }
                .buttonStyle(TTButtonStyle(.popoverSecondary))
            TTIconButton(.quit, label: "Quit Telltale", variant: .footer) { commands.quitTelltale() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(EdgeInsets(top: 6, leading: 4, bottom: 4, trailing: 4))
    }

    private func perform(_ action: PopoverModel.Banner.Action) {
        switch action {
        case .show(let page):
            commands.openDashboard(page)
        case .quit(let key):
            guard let app = live.app(key) else { return }
            let target = app.target
            Task { _ = await actions.quit(target) }
        }
    }
}

/// DESIGN §3.1 #1: HStack gap 10, padding 8 top / 10 horizontal / 10 bottom: glyph 20; "Telltale"
/// `sectionTitle` over a 7×7 status dot + status line (`caption` `textSecondary`, gap 6); Pause; Settings (26).
struct PopoverHeader: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.appCommands) private var commands

    var body: some View {
        let alert = live.alert
        let paused = live.isPausedPhase
        HStack(spacing: 10) {
            PopoverGlyph(state: alert)
            VStack(alignment: .leading, spacing: 0) {
                Text("Telltale").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).cssLine(13)
                HStack(spacing: 6) {
                    TTDot(color: Self.dotColor(alert, paused: paused))
                    Text(paused ? "Sampling paused" : StatusLine.text(for: alert))
                        .font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                }
                .cssLine(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TTIconButton(paused ? .play : .pause, label: paused ? "Resume sampling" : "Pause sampling",
                         variant: .popover) { commands.setPaused(!paused) }
            TTIconButton(.settings, label: "Settings", variant: .popover) { commands.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
    }

    static func dotColor(_ alert: AlertState, paused: Bool) -> Color {
        if paused || alert.paused { return TTColor.statusPaused }
        return alert.level == .calm ? TTColor.statusCalm : TTColor.level(alert.level)
    }
}

/// DESIGN §3.1 #11: HStack gap 10, padding 8×10: tile 26; "Top consumer" `caption` `textSecondary`, name
/// `body13`, detail `caption` `textSecondary`; small secondary "Quit" (disabled when not user-owned).
struct TopConsumerView: View {
    let consumer: PopoverModel.Consumer
    @Environment(\.processActions) private var actions
    @Environment(\.appCommands) private var commands

    var body: some View {
        let app = consumer.app
        HStack(spacing: 10) {
            TTAppTile(identity: app.identity, name: app.name, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Top consumer").font(TTFont.caption).foregroundStyle(TTColor.textSecondary).cssLine(11)
                Text(app.name).font(TTFont.body13).foregroundStyle(TTColor.textPrimary).lineLimit(1).cssLine(13)
                Text(consumer.detail).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                    .monospacedDigit().lineLimit(1).cssLine(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { commands.inspectApp(app.identity.key) }
            Button("Quit") {
                let target = app.target
                Task { _ = await actions.quit(target) }
            }
            .buttonStyle(TTButtonStyle(.smallSecondary))
            .disabled(!app.isCurrentUser || !actions.canControl(app.target))
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
    }
}
