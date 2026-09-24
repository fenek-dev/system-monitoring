import Foundation

/// A process instance: pid + kernel start time, so pid reuse yields a new identity.
public struct ProcessID: Hashable, Sendable, Codable {
    public var pid: Int32
    /// kinfo_proc `p_starttime` (µs since epoch); 0 = unknown.
    /// `ProcessID(pid: p, startTimeUs: 0)` (start time unknown, e.g. NStat before resolution) matches the live
    /// process with that pid in the current process list (any start time); if none exists, its data goes to
    /// `AppKey.system` (unattributed).
    public var startTimeUs: UInt64

    public init(pid: Int32 = 0, startTimeUs: UInt64 = 0) {
        self.pid = pid
        self.startTimeUs = startTimeUs
    }

    /// Synthetic row carrying a resource coalition's residual usage: pid -1, `startTimeUs` = coalition id.
    public static func coalitionResidual(_ coalitionID: UInt64) -> ProcessID {
        ProcessID(pid: -1, startTimeUs: coalitionID)
    }

    /// ICR-13 synthetic row "Exited processes": CPU/disk/energy of an all-visible coalition's members that started
    /// and/or exited between ticks. pid -2, `startTimeUs` = coalition id. Never controllable.
    public static func exitedResidual(_ coalitionID: UInt64) -> ProcessID {
        ProcessID(pid: -2, startTimeUs: coalitionID)
    }

    /// True for synthetic rows (pid < 0).
    public var isSynthetic: Bool { pid < 0 }

    /// True for the ICR-13 "Exited processes" row (label "Exited processes", not "System").
    public var isExitedResidual: Bool { pid == -2 }
}

/// Grouping key of an app (see ARCHITECTURE §5.1 grouping rules).
public struct AppKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable { case app, process, system, other }

    public let kind: Kind
    /// app: bundle id (fallback bundle path); process: executable path; "system"; "other".
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static let system = AppKey(kind: .system, id: "system")
    public static let other = AppKey(kind: .other, id: "other")

    /// `"<kind>:<id>"`, e.g. `"app:com.apple.FinalCut"`.
    public var description: String { "\(kind.rawValue):\(id)" }
}

public struct AppIdentity: Hashable, Sendable, Codable {
    public var key: AppKey
    /// "Final Cut Pro", "System", "node".
    public var displayName: String
    public var bundlePath: String?

    public init(key: AppKey = .other, displayName: String = "", bundlePath: String? = nil) {
        self.key = key
        self.displayName = displayName
        self.bundlePath = bundlePath
    }
}

public enum Category: String, CaseIterable, Sendable, Codable { case cpu, gpu, memory, network, thermals, power, disk }
public enum IconArc: String, CaseIterable, Sendable, Codable { case cpu, gpu, memory, network, thermals }

/// `[IconArc: …]` (`AlertState.arcs`) encodes as a JSON object keyed by rawValue.
extension IconArc: CodingKeyRepresentable {}

public enum Provenance: String, Sendable, Codable {
    /// Per-pid counters readable (own uid, or rusage permitted).
    case measured
    /// Counters filled from the process's resource-coalition residual (estimated).
    case coalition
    /// EPERM, not individually attributable; its usage is in a coalition residual row.
    case restricted
}

public enum MemorySource: Sendable, Codable, Hashable {
    /// `ri_phys_footprint`.
    case footprint
    /// From `/bin/ps` (restricted pids); age since the ps run.
    case rss(ageNs: UInt64)
}
