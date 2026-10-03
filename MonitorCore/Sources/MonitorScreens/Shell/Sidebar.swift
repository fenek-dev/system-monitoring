import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.0 sidebar: 220 wide incl. 1-pt `edgeSidebar`, `bgSidebar`, padding 0/10/12; 52-pt traffic-light
/// spacer; sections Monitor / System / Activity of `TTSidebarItem`s with live trailing values; device footer.
public struct Sidebar: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.unitPreferences) private var units

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: ShellStyle.headerHeight)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(DashboardPage.Section.allCases, id: \.self) { section in
                    Text(section.title)
                        .font(ShellStyle.captionStrong).foregroundStyle(ShellStyle.textTertiary)
                        .padding(.top, 10).padding(.horizontal, 10).padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(DashboardPage.allCases.filter { $0.section == section }, id: \.self) { page in
                        Button { nav.page = page } label: {
                            TTSidebarItem(page: page, value: Self.value(for: page, live: live, units: units),
                                          selected: nav.page == page)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(page.title)
                        .accessibilityAddTraits(nav.page == page ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 0)
            DeviceHeader()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: ShellStyle.sidebarWidth - 1)
        .frame(maxHeight: .infinity)
        .background(ShellStyle.bgSidebar)
        .overlay(alignment: .trailing) { ShellStyle.edgeSidebar.frame(width: 1).offset(x: 1) }
        .padding(.trailing, 1)
    }

    /// Trailing values (DESIGN §3.0): CPU `{cpu}%`, GPU `{gpu}%`, Memory `{used} GB`, Network `{down rate}`,
    /// Thermals `{socAvg}°`, Power `{package} W`, Disk and Storage `{free} GB free`; Overview/Processes/History none.
    /// Unavailable → "—" (TTFormat's nil rule).
    @MainActor public static func value(for page: DashboardPage, live: LiveModel, units: UnitPreferences) -> String? {
        switch page {
        case .overview, .processes, .history:
            return nil
        case .cpu:
            return TTFormat.percent(live.cpu.usage)
        case .gpu:
            return TTFormat.percent(live.gpu.usage)
        case .memory:
            return TTFormat.memory(live.memory.used, style: .headline)          // §5.3 headline: "45.5 GB"
        case .network:
            return TTFormat.rate(live.network.rxBps, units: units)
        case .thermals:
            let t = TTFormat.temperature(live.thermals.socAverage, units: units)
            return t.hasSuffix("°C") || t.hasSuffix("°F") ? String(t.dropLast()) : t
        case .power:
            return TTFormat.watts(live.power.packageWatts)
        case .disk, .storage:
            // Ruling (CP2): free = available capacity (`availableBytes`, statfs/container free = diskutil);
            // purgeable is separate. Same field and format as the Disk page's "Free space".
            guard let v = live.disk.bootVolume else { return ShellFormat.freeSpace(nil) }   // "—"
            return ShellFormat.freeSpace(v) + " free"                                      // §3.0 "{free} GB free"
        }
    }
}

extension DashboardPage.Section {
    var title: String {
        switch self {
        case .monitor: "Monitor"
        case .system: "System"
        case .activity: "Activity"
        }
    }
}
