import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Dashboard window content (DESIGN §3.0): custom sidebar (220) + main column (page header 52 + page).
/// Pages (W5) own their content padding (20) and scrolling; the shell gives them the area under the header on
/// `bgWindow` and reads their `.pageHeader(…)` preferences. Needs the `telltaleEnvironment`.
public struct DashboardRoot: View {
    @Environment(NavigationModel.self) private var nav
    @State private var headerConfig = PageHeaderConfig()
    /// Window-level confirm dialog (DESIGN §2.26), offered to pages as `\.presentConfirmDialog`.
    @State private var dialogs = ConfirmDialogHost()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                PageHeader(config: headerConfig)
                Self.page(nav.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(ShellStyle.bgWindow)
                    .onPreferenceChange(PageHeaderPreferenceKey.self) { headerConfig = $0 }
            }
        }
        .environment(\.presentConfirmDialog, dialogs.presenter)
        // Scrim over the whole window content (sidebar + header + page), content underneath disabled.
        .ttConfirmDialog(dialogs.current.map { r in
            TTConfirmDialog(title: r.title, message: r.message, confirmTitle: r.confirmTitle,
                            onConfirm: { dialogs.confirm() }, onCancel: { dialogs.cancel() })
        })
        .frame(minWidth: ShellStyle.dashboardMinSize.width, minHeight: ShellStyle.dashboardMinSize.height)
        .background(ShellStyle.bgWindow)
        .ignoresSafeArea()
        .onChange(of: nav.page) { headerConfig = PageHeaderConfig() }
        .onDisappear { dialogs.cancelAll() }                     // window closed: pending confirm → false
    }

    /// Page registry (one place; W5 pages are built from their public `init()`).
    @MainActor @ViewBuilder public static func page(_ page: DashboardPage) -> some View {
        switch page {
        case .overview: OverviewPage()
        case .cpu: CPUPage()
        case .gpu: GPUPage()
        case .memory: MemoryPage()
        case .network: NetworkPage()
        case .thermals: ThermalsPage()
        case .power: PowerPage()
        case .disk: DiskPage()
        case .processes: ProcessesPage()
        case .history: HistoryPage()
        }
    }
}
