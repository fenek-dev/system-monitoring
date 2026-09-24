import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Menu bar popover content (DESIGN §3.1–3.2). `PopoverContainer` (W4) adds the 360-pt chrome and padding 6.
/// Top to bottom: header, alert banners, full rows, divider, compact rows, divider, top consumer, divider, footer.
/// Rows follow `PopoverLayout` (order, hidden); a divider is dropped when either side is empty.
///
/// Invalidation: this body reads only the layout and the expansion state. Each row, the banners and the top
/// consumer are separate views that observe only what they show, and rows are `Equatable`, so e.g. a memory-only
/// update does not rebuild the Power/Disk rows (sparkline rows follow the shared per-tick series counter).
public struct PopoverRoot: View {
    @Environment(\.popoverLayout) private var layout
    @State private var expanded: Set<MonitorModel.Category>
    @State private var feedback: String?

    public init() { _expanded = State(initialValue: []) }

    /// Rows initially expanded (snapshots of the ADDED expansion).
    public init(expanded: Set<MonitorModel.Category>) { _expanded = State(initialValue: expanded) }

    public var body: some View {
        let sections = PopoverModel.sections(layout)
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader()
            PopoverBanners(feedback: $feedback)
            rows(sections.full)
            if !sections.full.isEmpty && !sections.compact.isEmpty { PopoverDivider() }
            rows(sections.compact)
            PopoverConsumerSection(dividerAbove: !(sections.full.isEmpty && sections.compact.isEmpty),
                                   feedback: $feedback)
            PopoverDivider()
            if let feedback {
                TTToast(feedback)
                    .padding(.horizontal, 10).padding(.top, 2)
                    .transition(.opacity)
                    .task(id: feedback) {
                        try? await Task.sleep(for: TTToast.lifetime)
                        self.feedback = nil
                    }
            }
            PopoverFooter()
        }
        // CSS border-box: content starts inside the 1-pt side borders, 7 from the panel edge (vertical measured flush).
        .padding(.horizontal, 1)
    }

    private func rows(_ categories: [MonitorModel.Category]) -> some View {
        ForEach(categories, id: \.self) { c in
            PopoverCategoryRow(category: c, expanded: expanded.contains(c)) {
                withAnimation(.easeInOut(duration: 0.18)) { expanded = PopoverModel.toggled(expanded, c) }
            }
        }
    }
}

/// 1 pt `separator`, margin 4 vertical, 10 horizontal.
struct PopoverDivider: View {
    var body: some View { TTSeparator().padding(.vertical, 4).padding(.horizontal, 10) }
}

/// One category row: observes only its own category (plus alert/health), hands plain data to the `Equatable`
/// `PopoverRowView`.
struct PopoverCategoryRow: View {
    let category: MonitorModel.Category
    let expanded: Bool
    let toggle: () -> Void
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units
    /// Grow-only Live rate ceiling for the sparkline while the popover is open (DESIGN §5.10, M5).
    @State private var ceilings = LiveCeilings()

    var body: some View {
        PopoverRowView(row: PopoverModel.row(category, live: live, units: units, ceilings: ceilings), expanded: expanded,
                       topApps: expanded ? PopoverModel.expansionApps(category, live: live) : [], toggle: toggle)
            .equatable()
            .environment(\.ttChartGapBridge, ChartSegments.liveBridgeSlots)   // Live 1-s grid sparklines (N2)
    }
}

/// One `TTAlertBanner` per active alert, most severe first (gap 6 between stacked banners comes from their margins).
struct PopoverBanners: View {
    @Binding var feedback: String?
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units
    @Environment(\.appCommands) private var commands
    @Environment(\.processActions) private var actions

    var body: some View {
        let ops = PopoverActions(commands: commands, actions: actions, live: live)
        ForEach(PopoverModel.banners(live: live, units: units, canControl: actions.canControl)) { banner in
            PopoverBannerView(banner: banner) { action in
                Task { if let f = await ops.perform(action) { feedback = f } }
            }
            .equatable()
        }
    }
}

/// Divider + top consumer; observes apps and alert only.
struct PopoverConsumerSection: View {
    let dividerAbove: Bool
    @Binding var feedback: String?
    @Environment(LiveModel.self) private var live
    @Environment(\.appCommands) private var commands
    @Environment(\.processActions) private var actions

    var body: some View {
        if let consumer = PopoverModel.consumer(live: live) {
            let ops = PopoverActions(commands: commands, actions: actions, live: live)
            if dividerAbove { PopoverDivider() }
            TopConsumerView(consumer: consumer, canQuit: consumer.app.isCurrentUser && actions.canControl(consumer.app.target),
                            open: { ops.openApp(consumer.app.identity.key) },
                            quit: { Task { if let f = await ops.quit(consumer.app) { feedback = f } } })
                .equatable()
        }
    }
}

/// HStack gap 8, padding 6 top, 4 horizontal, 4 bottom: Open Dashboard (flex), History, Overlay toggle (spec
/// 2026-09-25 overlay; accent tint while on), Quit Telltale (ADDED).
struct PopoverFooter: View {
    @Environment(LiveModel.self) private var live
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @Environment(\.appCommands) private var commands
    @Environment(\.processActions) private var actions

    var body: some View {
        let ops = PopoverActions(commands: commands, actions: actions, live: live)
        let hotKey = settings?.overlayHotKey ?? .defaultOverlay
        HStack(spacing: 8) {
            Button("Open Dashboard") { ops.openDashboard() }
                .buttonStyle(TTButtonStyle(.popoverPrimary))
                .keyboardShortcut("d", modifiers: .command)
            Button("History") { ops.openHistory() }
                .buttonStyle(TTButtonStyle(.popoverSecondary))
            let overlayOn = settings?.overlayEnabled == true
            TTIconButton(.overlay, label: "Overlay (\(hotKey.display))", variant: .footer,
                         tint: overlayOn ? TTColor.accent : nil) { ops.toggleOverlay() }
                .accessibilityValue(Self.overlayAccessibilityValue(enabled: overlayOn))
                .accessibilityAddTraits(.isToggle)
            TTIconButton(.quit, label: "Quit Warden", variant: .footer) { ops.quitTelltale() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(EdgeInsets(top: 6, leading: 4, bottom: 4, trailing: 4))
    }

    /// VoiceOver state of the overlay toggle (the tint alone is visual only).
    static func overlayAccessibilityValue(enabled: Bool) -> String { enabled ? "On" : "Off" }
}

/// DESIGN §3.1 #1: HStack gap 10, padding 8 top / 10 horizontal / 10 bottom: glyph 20; "Telltale"
/// `sectionTitle` over a 7×7 status dot + status line (`caption` `textSecondary`, gap 6); Pause; Settings (26).
struct PopoverHeader: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.appCommands) private var commands
    @Environment(\.processActions) private var actions

    var body: some View {
        let alert = live.alert
        let paused = live.isPausedPhase
        let ops = PopoverActions(commands: commands, actions: actions, live: live)
        HStack(spacing: 10) {
            TTStatusGlyph(state: alert, size: 20, template: false)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("Warden").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).cssLine(13)
                HStack(spacing: 6) {
                    TTDot(color: Self.dotColor(alert, paused: paused))
                    Text(paused ? "Sampling paused" : StatusLine.text(for: alert))
                        .font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                }
                .cssLine(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            TTIconButton(paused ? .play : .pause, label: paused ? "Resume sampling" : "Pause sampling",
                         variant: .popover) { ops.setPaused(!paused) }
            TTIconButton(.settings, label: "Settings", variant: .popover) { ops.openSettings() }
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
struct TopConsumerView: View, Equatable {
    let consumer: PopoverModel.Consumer
    let canQuit: Bool
    let open: () -> Void
    let quit: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.consumer == b.consumer && a.canQuit == b.canQuit }

    var body: some View {
        let app = consumer.app
        HStack(spacing: 10) {
            TTAppTile(identity: app.identity, name: app.name, size: 26)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Top consumer").font(TTFont.caption).foregroundStyle(TTColor.textSecondary).cssLine(11)
                    Text(app.name).font(TTFont.body13).foregroundStyle(TTColor.textPrimary).lineLimit(1).cssLine(13)
                    Text(consumer.detail).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                        .monospacedDigit().lineLimit(1).cssLine(11)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show in Processes")
            Button("Quit", action: quit)
                .buttonStyle(TTButtonStyle(.smallSecondary))
                .disabled(!canQuit)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
    }
}
