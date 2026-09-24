import Foundation
import MonitorModel

/// In-memory history for Live charts: system metrics per frame plus per-app series for the top apps.
/// A `nil` entry is a gap (pause, missed ticks, clock jump); gaps render as breaks in the line.
public struct LiveHistory: Sendable {
    struct Entry<Value: Sendable>: Sendable {
        var time: Date
        var value: Value?          // nil = gap
    }

    /// A gap is inserted when two frames are further apart than this many expected intervals.
    static let gapFactor = 2.5

    public let capacity: Int
    public let appCapacity: Int
    public let maxTrackedApps: Int

    private var system: RingBuffer<Entry<SystemMetrics>>
    private var apps: [AppKey: RingBuffer<Entry<AppMetrics>>] = [:]
    /// Last time each tracked app was in the top `maxTrackedApps` (eviction order).
    private var lastInTop: [AppKey: Date] = [:]
    private var lastFrameTime: Date?
    private var lastExpectedInterval: Duration?

    public init(capacity: Int = 300, appCapacity: Int = 120, maxTrackedApps: Int = 64) {
        self.capacity = max(1, capacity)
        self.appCapacity = max(1, appCapacity)
        self.maxTrackedApps = max(0, maxTrackedApps)
        system = RingBuffer(capacity: self.capacity)
    }

    /// Time of the newest entry (frame or gap).
    public var latestTime: Date? { system.last?.time }
    public var trackedAppCount: Int { apps.count }
    public var isEmpty: Bool { system.isEmpty }

    /// Appends one frame. Returns false (and changes nothing) for a frame at the same time as the previous one.
    /// A frame older than the previous one (wall clock moved back) restarts the history.
    @discardableResult
    public mutating func append(_ frame: SystemFrame) -> Bool {
        let t = frame.wallTime
        let expected = frame.mode.interval ?? .seconds(1)
        if let last = lastFrameTime {
            if t == last { return false }
            if t < last {
                removeAll()
            } else {
                let allowed = max(expected, lastExpectedInterval ?? expected)
                let gap = t.timeIntervalSince(last)
                if gap > Self.gapFactor * allowed.seconds {
                    appendGap(at: last.addingTimeInterval(gap / 2))
                }
            }
        }
        lastFrameTime = t
        lastExpectedInterval = expected
        system.append(Entry(time: t, value: frame.metrics))
        appendApps(frame.apps, at: t)
        return true
    }

    /// Appends a gap (no-op if the newest entry already is one).
    public mutating func appendGap(at time: Date) {
        guard let last = system.last, last.value != nil else { return }
        system.append(Entry(time: time, value: nil))
        for key in apps.keys { apps[key]!.append(Entry(time: time, value: nil)) }
    }

    public mutating func removeAll() {
        system.removeAll()
        apps.removeAll(keepingCapacity: true)
        lastInTop.removeAll(keepingCapacity: true)
        lastFrameTime = nil
        lastExpectedInterval = nil
    }

    /// Points with `time ≥ newest − window`, oldest first.
    public func series(_ metric: HistoryMetric, window: Duration) -> [SeriesPoint] {
        points(system, window: window) { $0[metric] }
    }

    /// Empty unless `app` has been among the top tracked apps.
    public func appSeries(_ app: AppKey, _ metric: AppMetric, window: Duration) -> [SeriesPoint] {
        guard let buffer = apps[app] else { return [] }
        return points(buffer, window: window) { $0[metric] }
    }

    // MARK: - Private

    private func points<V>(_ buffer: RingBuffer<Entry<V>>, window: Duration, _ value: (V) -> Double?) -> [SeriesPoint] {
        guard let newest = latestTime else { return [] }
        let start = newest.addingTimeInterval(-window.seconds)
        var i = buffer.endIndex
        while i > buffer.startIndex, buffer[i - 1].time >= start { i -= 1 }
        var out: [SeriesPoint] = []
        out.reserveCapacity(buffer.endIndex - i)
        for e in buffer[i...] { out.append(SeriesPoint(time: e.time, value: e.value.flatMap(value))) }
        return out
    }

    private mutating func appendApps(_ frameApps: [AppSample], at t: Date) {
        guard maxTrackedApps > 0 else { return }
        var present: [AppKey: AppSample] = [:]
        present.reserveCapacity(frameApps.count)
        for a in frameApps { present[a.identity.key] = a }

        for a in frameApps.prefix(maxTrackedApps) {
            lastInTop[a.identity.key] = t
            if apps[a.identity.key] == nil { apps[a.identity.key] = RingBuffer(capacity: appCapacity) }
        }
        if apps.count > maxTrackedApps {
            let evict = apps.keys.sorted { (lastInTop[$0] ?? .distantPast) < (lastInTop[$1] ?? .distantPast) }
                .prefix(apps.count - maxTrackedApps)
            for key in evict {
                apps[key] = nil
                lastInTop[key] = nil
            }
        }
        for key in apps.keys {
            let metrics = present[key].map(Self.metrics(of:))
            apps[key]!.append(Entry(time: t, value: metrics))
        }
    }

    static func metrics(of app: AppSample) -> AppMetrics {
        var m = AppMetrics()
        for metric in AppMetric.allCases { m[metric] = app.value(for: metric) }
        return m
    }
}

extension Duration {
    /// Seconds as Double.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}
