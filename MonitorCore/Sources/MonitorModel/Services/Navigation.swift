import Foundation

public enum DashboardPage: String, CaseIterable, Sendable, Codable {
    case overview, cpu, gpu, memory, network, thermals, power, disk, storage, processes, history

    /// Sidebar title (DESIGN.md sidebar).
    public var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .thermals: "Thermals"
        case .power: "Power & Battery"
        case .disk: "Disk"
        case .storage: "Storage"
        case .processes: "Processes"
        case .history: "History"
        }
    }

    /// Sidebar section: Monitor (overview…thermals), System (power, disk, storage), Activity (processes, history).
    public var section: Section {
        switch self {
        case .overview, .cpu, .gpu, .memory, .network, .thermals: .monitor
        case .power, .disk, .storage: .system
        case .processes, .history: .activity
        }
    }

    public enum Section: String, Sendable, CaseIterable { case monitor, system, activity }
}
