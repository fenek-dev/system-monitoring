import MonitorModel
import MonitorUIKit
import SwiftUI

/// `Equatable` host of W3's `TTPopoverRow` (DESIGN §2.22): compares the row data only, so a tick that leaves a
/// row's data unchanged does not rebuild it. Expansion lines come from `topApps` (TTPopoverRow ranks them);
/// double-click / app-line clicks go through `appCommands` inside TTPopoverRow.
struct PopoverRowView: View, Equatable {
    let row: PopoverModel.Row
    let expanded: Bool
    let topApps: [AppSample]
    let toggle: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.expanded == b.expanded && a.topApps == b.topApps
    }

    var body: some View {
        TTPopoverRow(category: row.category, subtitle: row.subtitle, value: row.value,
                     unavailableReason: row.unavailableReason, points: row.points, yDomain: row.domain,
                     compact: row.compact,
                     expanded: Binding(get: { expanded }, set: { if $0 != expanded { toggle() } }),
                     topApps: topApps, level: row.stress, showsCollecting: !row.sensorDown)
    }
}

/// `Equatable` host of W3's `TTAlertBanner` (DESIGN §2.23).
struct PopoverBannerView: View, Equatable {
    let banner: PopoverModel.Banner
    let perform: (PopoverModel.Banner.Action) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.banner == b.banner }

    var body: some View {
        TTAlertBanner(title: "Alert", message: banner.message, level: banner.level,
                      actions: banner.buttons.map { b in
                          BannerAction(id: b.title, title: b.title) { perform(b.action) }
                      })
    }
}
