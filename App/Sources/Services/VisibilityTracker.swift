import MonitorLive
import MonitorModel
import MonitorRuntime
import MonitorScreens
import os

/// App glue for `MonitorScreens.VisibilityTracker` (the pure reducer lives in Shell): builds the tracker whose
/// sink drives `runtime.setVisibility` + `live.isPresenting`, and follows the NavigationModel's page/selection.
/// Window/panel facts are pushed by `DashboardWindowController` and `PopoverPanelController`.
@MainActor
final class VisibilityWiring {
    let tracker: VisibilityTracker
    private var navLoop: ObservationLoop<NavKey>?
    private static let log = Logger(subsystem: "dev.telltale", category: "Visibility")

    private struct NavKey: Equatable {
        var page: DashboardPage
        var selection: NavigationModel.ProcessSelection?
    }

    init(env: AppEnvironment) {
        let log = Self.log
        tracker = VisibilityTracker { [env] v in
            env.live.isPresenting = v.mode == .interactive
            env.runtime.setVisibility(v)
            log.notice("""
                mode=\(v.mode == .interactive ? "interactive" : "background", privacy: .public) \
                popover=\(v.popoverOpen) dashboard=\(v.dashboardVisible) \
                page=\(v.page?.rawValue ?? "-", privacy: .public) demand=0x\(String(v.demand.rawValue, radix: 16), privacy: .public) \
                inspected=\(v.inspectedApp?.description ?? "-", privacy: .public)
                """)
        }
        let nav = env.navigation
        navLoop = ObservationLoop({ NavKey(page: nav.page, selection: nav.selection) }) { [tracker] key in
            tracker.update {
                $0.page = key.page
                $0.selection = key.selection
            }
        }
    }
}
