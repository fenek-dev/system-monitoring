import MonitorModel
import MonitorUIKit
import SwiftUI

/// `Equatable` host of W3's `TTPopoverRow` (DESIGN §2.22): compares the row data only, so a tick that leaves a
/// row's data unchanged does not rebuild it. The click (dashboard page) and the hover events for the top-apps
/// flyout (`\.popoverRowHover`, set by `PopoverRoot`) are TTPopoverRow's.
struct PopoverRowView: View, Equatable {
    let row: PopoverModel.Row

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row }

    var body: some View {
        TTPopoverRow(category: row.category, subtitle: row.subtitle, value: row.value,
                     unavailableReason: row.unavailableReason, points: row.points, yDomain: row.domain,
                     compact: row.compact, level: row.stress, showsCollecting: !row.sensorDown)
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
