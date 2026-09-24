import Foundation
import MonitorModel
import Observation

// ARCHITECTURE §5.10. Written by W0b; owned by W4.

@MainActor @Observable public final class NavigationModel {
    public var page: DashboardPage = .overview
    public var range: HistoryRange = .live
    public var historyRange: HistoryRange = .day
    public var processesMode: ProcessesMode = .apps
    public var selection: ProcessSelection?
    public var historyScrub: Date?

    public enum ProcessesMode: String, Sendable { case apps, processes }
    public enum ProcessSelection: Hashable, Sendable { case app(AppKey), process(ProcessID) }

    public init() {}

    /// AppCommands.openDashboard: nil keeps the current page.
    public func open(_ page: DashboardPage?) {
        if let page { self.page = page }
    }

    /// AppCommands.inspectApp: Processes in Apps mode with the app selected (→ `UIVisibility.inspectedApp`).
    public func inspect(_ app: AppKey) {
        page = .processes
        processesMode = .apps
        selection = .app(app)
    }

    /// The range the current page's header control edits (History keeps its own, default 24H).
    public var currentRange: HistoryRange {
        get { page == .history ? historyRange : range }
        set { if page == .history { historyRange = newValue } else { range = newValue } }
    }
}
