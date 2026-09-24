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
}
