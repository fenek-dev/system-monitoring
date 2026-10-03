import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

// MARK: - Page → header hooks (used by W5 pages; the shell owns the header itself)

/// What a page tells the shell header. Pages set it with `.pageHeader(subtitle:)` and
/// `.pageHeaderTrailing(id:_:)`; anything unset falls back to `PageHeader.defaultSubtitle`/the range control.
public struct PageHeaderConfig: Equatable {
    public var subtitle: String?
    /// Replaces the range control (Processes: the 220-pt search field). Compared by `id`.
    public var trailing: Trailing?

    public struct Trailing: Equatable {
        public var id: String
        public var view: AnyView
        public static func == (a: Trailing, b: Trailing) -> Bool { a.id == b.id }
    }

    public init(subtitle: String? = nil, trailing: Trailing? = nil) {
        self.subtitle = subtitle
        self.trailing = trailing
    }
}

struct PageHeaderPreferenceKey: PreferenceKey {
    static var defaultValue: PageHeaderConfig { PageHeaderConfig() }
    static func reduce(value: inout PageHeaderConfig, nextValue: () -> PageHeaderConfig) {
        let n = nextValue()
        if let s = n.subtitle { value.subtitle = s }
        if let t = n.trailing { value.trailing = t }
    }
}

public extension View {
    /// Page subtitle under the h1 (DESIGN §3.x "Header: … Sub: …").
    func pageHeader(subtitle: String?) -> some View {
        preference(key: PageHeaderPreferenceKey.self, value: PageHeaderConfig(subtitle: subtitle))
    }

    /// A header control that replaces the range control (e.g. Processes search). Change `id` when the view's
    /// identity/content must be re-read; bindings inside `view` stay live.
    func pageHeaderTrailing<V: View>(id: String, @ViewBuilder _ view: () -> V) -> some View {
        preference(key: PageHeaderPreferenceKey.self,
                   value: PageHeaderConfig(trailing: .init(id: id, view: AnyView(view()))))
    }
}

// MARK: - Header

/// DESIGN §3.0 page header: 52 tall, `bgHeader`, 1-pt `edgeHeader` bottom, padding 0 16 0 20, HStack gap 10.
/// Title block; trailing: range `TTSegmented` (or the page's trailing view), Pause/Resume (not on History),
/// Settings.
public struct PageHeader: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.appCommands) private var commands
    private let config: PageHeaderConfig

    public init(config: PageHeaderConfig = PageHeaderConfig()) {
        self.config = config
    }

    public var body: some View {
        @Bindable var nav = nav
        let page = nav.page
        let paused = live.isPausedPhase
        HStack(spacing: 10) {
            // Main@2x: title cap top 14 pt and subtitle cap top 31 pt below the band top, i.e. the title line
            // advances 16.5 pt (≈ 1.1 × 15) rather than SF's default 18 → spacing −1.5.
            VStack(alignment: .leading, spacing: -1.5) {
                Text(page.title)
                    .font(ShellStyle.pageTitle).foregroundStyle(ShellStyle.textPrimary)
                    .lineLimit(1)
                if let sub = config.subtitle ?? Self.defaultSubtitle(page: page, live: live, nav: nav) {
                    Text(sub)
                        .font(ShellStyle.caption).foregroundStyle(ShellStyle.textSecondary)
                        .monospacedDigit().lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailing = config.trailing {
                trailing.view
            } else if page != .processes {
                TTSegmented(selection: $nav.currentRange,
                            options: HistoryRange.allCases.map { ($0, $0.label) })
                    .accessibilityLabel("Range")
            }
            if page != .history {
                ShellIconButton(icon: paused ? .play : .pause,
                                help: paused ? "Resume sampling" : "Pause sampling") {
                    commands.setPaused(!paused)
                }
            }
            ShellIconButton(icon: .settings, help: "Settings") { commands.openSettings() }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: ShellStyle.headerHeight)                 // 52-pt band (traffic lights centred at y 26)
        .background(ShellStyle.bgHeader)
        .padding(.bottom, 1)                                     // + 1-pt edge *below* the band (Main@2x: 52 + 1)
        .background(alignment: .bottom) {                        // black @ 0.45 over the header colour
            ShellStyle.edgeHeader.background(ShellStyle.bgHeader).frame(height: 1)
        }
    }

    /// Subtitles the shell can derive (DESIGN §3.4–3.13 "Sub:"); pages override with `.pageHeader(subtitle:)`.
    @MainActor public static func defaultSubtitle(page: DashboardPage, live: LiveModel,
                                                  nav: NavigationModel) -> String? {
        let d = live.device
        let chip = d.chipName
        switch page {
        case .overview:
            if live.isPausedPhase { return "Sampling paused" }
            if nav.range != .live { return "Showing last \(nav.range.phrase)" }
            return "Sampling every second · all values live"
        case .cpu:
            let n = d.performanceCores + d.efficiencyCores
            guard n > 0 else { return chip }
            return "\(chip) · \(n) cores (\(d.performanceCores) performance + \(d.efficiencyCores) efficiency)"
        case .gpu:
            var parts = [chip]
            if let g = d.gpuCores { parts.append("\(g)-core GPU") }
            if let a = d.neuralEngineCores { parts.append("\(a)-core Neural Engine") }
            return parts.joined(separator: " · ")
        case .memory:
            guard d.memoryBytes > 0 else { return nil }
            var parts = ["\(d.memoryBytes / 1_073_741_824) GB unified memory"]
            if let t = d.memoryType { parts.append(t) }
            if let b = d.memoryBandwidth { parts.append(b) }
            return parts.joined(separator: " · ")
        case .thermals:
            return "SoC sensors, fans and macOS thermal pressure"
        case .processes:
            let n = live.cpu.processCount ?? live.processes.count
            var parts = ["\(TTFormat.count(n)) processes"]
            if let t = live.cpu.threadCount { parts.append("\(TTFormat.count(t)) threads") }
            parts.append("select a row to inspect")
            return parts.joined(separator: " · ")
        case .history:
            return "Stored locally · \(nav.historyRange.resolutionPhrase) · kept for 30 days"
        case .network, .power, .disk, .storage:
            return nil                                    // page-provided (Wi-Fi link, battery, SSD model, scan root)
        }
    }
}

extension LiveModel {
    var isPausedPhase: Bool {
        if case .paused = phase { return true }
        return alert.paused
    }
}

extension HistoryRange {
    /// "Showing last {phrase}" (DESIGN §3.4).
    var phrase: String {
        switch self {
        case .live: "60 seconds"
        case .hour: "hour"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    /// DESIGN §3.13 History subtitle middle part.
    var resolutionPhrase: String {
        switch self {
        case .live: "1-second resolution for 60 s"
        case .hour: "15-second resolution for 1 hour"
        case .day: "5-minute resolution for 24 hours"
        case .week: "30-minute resolution for 7 days"
        case .month: "2-hour resolution for 30 days"
        }
    }
}
