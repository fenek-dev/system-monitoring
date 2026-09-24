import Foundation

/// Optional data the UI currently needs; sensors with `SensorCadence.requires` run only when requested.
public struct SamplingDemand: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let perCore = SamplingDemand(rawValue: 1 << 0)
    public static let connections = SamplingDemand(rawValue: 1 << 1)
    public static let rawTemperatures = SamplingDemand(rawValue: 1 << 2)
    public static let wifi = SamplingDemand(rawValue: 1 << 3)
    public static let smart = SamplingDemand(rawValue: 1 << 4)
    public static let volumes = SamplingDemand(rawValue: 1 << 5)
    public static let sleepAssertions = SamplingDemand(rawValue: 1 << 6)
    /// A visible process table (enables rootMemory).
    public static let processTable = SamplingDemand(rawValue: 1 << 7)
    /// Engine-set while the memory arc is ≥ elevated (enables rootMemory).
    public static let memoryAlert = SamplingDemand(rawValue: 1 << 8)
    public static let none: SamplingDemand = []
}

public struct UIVisibility: Sendable, Equatable {
    public var popoverOpen: Bool
    /// visible && !occluded && !miniaturized.
    public var dashboardVisible: Bool
    public var page: DashboardPage?
    /// Connections are collected only for this app.
    public var inspectedApp: AppKey?

    public init(
        popoverOpen: Bool = false,
        dashboardVisible: Bool = false,
        page: DashboardPage? = nil,
        inspectedApp: AppKey? = nil
    ) {
        self.popoverOpen = popoverOpen
        self.dashboardVisible = dashboardVisible
        self.page = page
        self.inspectedApp = inspectedApp
    }

    /// Interactive while the popover or the dashboard is visible, else background.
    /// (`paused` is set separately via `setPaused`, not derived from visibility.)
    public var mode: SamplingMode {
        popoverOpen || dashboardVisible ? .interactive : .background
    }

    /// Page → demand (only while the dashboard is visible): overview/gpu/memory/processes → .processTable;
    /// cpu → .perCore+.processTable; network → .wifi+.processTable; thermals → .rawTemperatures;
    /// disk → .processTable+.smart+.volumes; power → .processTable+.sleepAssertions; history → [].
    /// inspectedApp != nil → +.connections. The popover alone adds nothing.
    public var demand: SamplingDemand {
        guard dashboardVisible else { return .none }
        var d: SamplingDemand = switch page {
        case .overview, .gpu, .memory, .processes: .processTable
        case .cpu: [.perCore, .processTable]
        case .network: [.wifi, .processTable]
        case .thermals: .rawTemperatures
        case .disk: [.processTable, .smart, .volumes]
        case .power: [.processTable, .sleepAssertions]
        case .history, nil: .none
        }
        if inspectedApp != nil { d.insert(.connections) }
        return d
    }
}
