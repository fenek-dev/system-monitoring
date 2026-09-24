import Foundation

public enum AlertLevel: Int, Sendable, Codable, Comparable {
    case calm, elevated, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ActiveAlert: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: Sendable, Codable, Equatable {
        case thermalPressure(ThermalPressure), memoryPressure(MemoryPressureLevel), runawayApp(AppKey, cpuPercent: Double)
    }

    /// "thermal" | "memory" | "runaway:<key>".
    public var id: String {
        switch kind {
        case .thermalPressure: "thermal"
        case .memoryPressure: "memory"
        case .runawayApp(let key, _): "runaway:\(key)"
        }
    }

    public var kind: Kind, level: AlertLevel, arc: IconArc, since: Date
    public var culprit: AppIdentity?, culpritValue: Double?

    public init(
        kind: Kind = .thermalPressure(.nominal),
        level: AlertLevel = .calm,
        arc: IconArc = .thermals,
        since: Date = Date(timeIntervalSince1970: 0),
        culprit: AppIdentity? = nil,
        culpritValue: Double? = nil
    ) {
        self.kind = kind
        self.level = level
        self.arc = arc
        self.since = since
        self.culprit = culprit
        self.culpritValue = culpritValue
    }
}

public struct AlertState: Sendable, Codable, Equatable {
    public var level: AlertLevel
    public var arcs: [IconArc: AlertLevel]
    /// Level desc, then since asc.
    public var active: [ActiveAlert]
    /// +1 on each entry into `.critical`.
    public var pulseToken: Int
    /// Glyph dimmed (ruling).
    public var paused: Bool

    /// `arcs` defaults to every arc `.calm`.
    public init(
        level: AlertLevel = .calm,
        arcs: [IconArc: AlertLevel] = Dictionary(uniqueKeysWithValues: IconArc.allCases.map { ($0, AlertLevel.calm) }),
        active: [ActiveAlert] = [],
        pulseToken: Int = 0,
        paused: Bool = false
    ) {
        self.level = level
        self.arcs = arcs
        self.active = active
        self.pulseToken = pulseToken
        self.paused = paused
    }

    /// Nothing active, every arc calm, not paused.
    public static let calm = AlertState()
}
