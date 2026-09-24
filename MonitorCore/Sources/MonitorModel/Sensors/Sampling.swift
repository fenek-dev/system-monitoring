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

    /// Page → demand (only while the dashboard is visible). `.processTable` (enables the `ps` RSS sensor) only for
    /// pages whose tables show a per-process memory column: overview, memory, processes (ICR-7).
    /// cpu → .perCore; network → .wifi; thermals → .rawTemperatures; disk → .smart+.volumes;
    /// power → .sleepAssertions; gpu/history → []. inspectedApp != nil → +.connections+.processTable.
    /// The popover alone adds nothing.
    public var demand: SamplingDemand {
        guard dashboardVisible else { return .none }
        var d: SamplingDemand = switch page {
        case .overview, .memory, .processes: .processTable
        case .cpu: .perCore
        case .network: .wifi
        case .thermals: .rawTemperatures
        case .disk: [.smart, .volumes]
        case .power: .sleepAssertions
        case .gpu, .history, nil: .none
        }
        if inspectedApp != nil { d.formUnion([.connections, .processTable]) }
        return d
    }
}
