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
    /// ICR-10: the app whose inspector detail is expanded on Processes (a process selection maps to its app);
    /// nil otherwise. Set by ProcessesPage (W5c); drives `UIVisibility.inspectedApp` → connection sampling.
    public var inspectedApp: AppKey?

    public enum ProcessesMode: String, Sendable { case apps, processes }
    public enum ProcessSelection: Hashable, Sendable { case app(AppKey), process(ProcessID) }

    public init() {}

    /// AppCommands.openDashboard: nil keeps the current page.
    public func open(_ page: DashboardPage?) {
        if let page { self.page = page }
    }

    /// AppCommands.inspectApp: Processes in Apps mode with the app selected and its inspector open
    /// (`inspectedApp`, → `UIVisibility.inspectedApp`).
    public func inspect(_ app: AppKey) {
        page = .processes
        processesMode = .apps
        selection = .app(app)
        inspectedApp = app
    }

    /// The range the current page's header control edits (History keeps its own, default 24H).
    public var currentRange: HistoryRange {
        get { page == .history ? historyRange : range }
        set { if page == .history { historyRange = newValue } else { range = newValue } }
    }
}
