import Foundation

public struct HistoryEvent: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case thermalPressure, memoryPressure, runawayApp, appEpisode, swapGrowth, samplingPaused, systemSleep
    }

    public var id: UUID, kind: Kind, start: Date, end: Date?, level: AlertLevel
    public var app: AppIdentity?, metric: AppMetric?, peak: Double?, label: String

    public init(
        id: UUID = UUID(),
        kind: Kind = .appEpisode,
        start: Date = Date(timeIntervalSince1970: 0),
        end: Date? = nil,
        level: AlertLevel = .calm,
        app: AppIdentity? = nil,
        metric: AppMetric? = nil,
        peak: Double? = nil,
        label: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.level = level
        self.app = app
        self.metric = metric
        self.peak = peak
        self.label = label
    }
}
