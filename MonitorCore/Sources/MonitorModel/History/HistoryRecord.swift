import Foundation

public struct AppRecord: Sendable, Codable, Equatable {
    public var identity: AppIdentity
    public var metrics: AppMetrics

    public init(identity: AppIdentity = AppIdentity(), metrics: AppMetrics = AppMetrics()) {
        self.identity = identity
        self.metrics = metrics
    }
}

public struct HistoryRecord: Sendable, Codable, Equatable {
    public var time: Date, interval: Duration, system: SystemMetrics
    /// Apps above the record thresholds + `.other`.
    public var apps: [AppRecord]

    public init(
        time: Date = Date(timeIntervalSince1970: 0),
        interval: Duration = .zero,
        system: SystemMetrics = SystemMetrics(),
        apps: [AppRecord] = []
    ) {
        self.time = time
        self.interval = interval
        self.system = system
        self.apps = apps
    }
}

/// One tick's output for the store (lives in Model so MonitorStore has no Engine dependency).
public struct RecordBatch: Sendable {
    public var record: HistoryRecord?
    public var events: [HistoryEvent]

    public init(record: HistoryRecord? = nil, events: [HistoryEvent] = []) {
        self.record = record
        self.events = events
    }
}

public struct AppShare: Sendable, Codable, Hashable, Identifiable {
    public var id: AppKey { identity.key }
    public var identity: AppIdentity
    public var value: Double
    public var fraction: Double

    public init(identity: AppIdentity = AppIdentity(), value: Double = 0, fraction: Double = 0) {
        self.identity = identity
        self.value = value
        self.fraction = fraction
    }
}

public struct AppAggregate: Sendable, Codable, Hashable {
    public var identity: AppIdentity
    public var average, peak: Double
    public var total: Double?

    public init(identity: AppIdentity = AppIdentity(), average: Double = 0, peak: Double = 0, total: Double? = nil) {
        self.identity = identity
        self.average = average
        self.peak = peak
        self.total = total
    }
}

public struct ExportSummary: Sendable, Equatable {
    public var rows: Int, bytes: Int
    public var url: URL

    public init(rows: Int = 0, bytes: Int = 0, url: URL = URL(fileURLWithPath: "/dev/null")) {
        self.rows = rows
        self.bytes = bytes
        self.url = url
    }
}
