import Foundation
import MonitorModel

/// In-memory history for Live charts: system metrics per frame plus per-app series for the top apps.
/// A `nil` entry is a gap (pause, missed ticks, clock jump); gaps render as breaks in the line.
///
/// Per-app series: an app gets a buffer when it enters the top `maxTrackedApps` of a frame (frame order =
/// cpu desc). While tracked it gets a point every frame (a gap when absent). When more than `maxTrackedApps`
/// are tracked, the ones longest out of the top are evicted **with their history**, so an app hovering around
/// rank `maxTrackedApps` can lose its series and restart it on re-entry.
///
/// Buffers live in a slot array mutated in place (no dictionary iteration while mutating → no copy-on-write
/// of the buffers per tick).
public struct LiveHistory: Sendable {
    struct Entry<Value: Sendable>: Sendable {
        var time: Date
        var value: Value?          // nil = gap
    }

    struct AppSlot: Sendable {
        var key: AppKey
        var buffer: RingBuffer<Entry<AppMetrics>>
        var lastInTop: Date
        var seen: Bool
    }

    /// A gap is inserted when two frames are further apart than this many expected intervals.
    static let gapFactor = 2.5

    public let capacity: Int
    public let appCapacity: Int
    public let maxTrackedApps: Int

    private var system: RingBuffer<Entry<SystemMetrics>>
    private var slots: [AppSlot] = []
    private var slotIndex: [AppKey: Int] = [:]
    private var lastFrameTime: Date?
    private var lastExpectedInterval: Duration?

    public init(capacity: Int = 300, appCapacity: Int = 120, maxTrackedApps: Int = 64) {
        self.capacity = max(1, capacity)
        self.appCapacity = max(1, appCapacity)
        self.maxTrackedApps = max(0, maxTrackedApps)
        system = RingBuffer(capacity: self.capacity)
        slots.reserveCapacity(self.maxTrackedApps + 1)
    }

    /// Time of the newest entry (frame or gap).
    public var latestTime: Date? { system.last?.time }
    public var trackedAppCount: Int { slots.count }
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

    /// Appends a gap (no-op if the newest entry already is one). Returns whether it appended.
    @discardableResult
    public mutating func appendGap(at time: Date) -> Bool {
        guard let last = system.last, last.value != nil else { return false }
        system.append(Entry(time: time, value: nil))
        for i in slots.indices { slots[i].buffer.append(Entry(time: time, value: nil)) }
        return true
    }

    public mutating func removeAll() {
        system.removeAll()
        slots.removeAll(keepingCapacity: true)
        slotIndex.removeAll(keepingCapacity: true)
        lastFrameTime = nil
        lastExpectedInterval = nil
    }

    /// Points with `time ≥ newest − window`, oldest first.
    public func series(_ metric: HistoryMetric, window: Duration) -> [SeriesPoint] {
        points(system, window: window) { $0[metric] }
    }

    /// Empty unless `app` is currently tracked.
    public func appSeries(_ app: AppKey, _ metric: AppMetric, window: Duration) -> [SeriesPoint] {
        guard let i = slotIndex[app] else { return [] }
        return points(slots[i].buffer, window: window) { $0[metric] }
    }

    // MARK: - Test hooks

    /// Base address of each tracked app's buffer storage (copy-on-write detection in tests).
    func appStorageAddresses() -> [AppKey: UnsafeRawPointer?] {
        Dictionary(uniqueKeysWithValues: slots.map { ($0.key, $0.buffer.storageAddress) })
    }

    var systemStorageAddress: UnsafeRawPointer? { system.storageAddress }

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
        for i in slots.indices { slots[i].seen = false }

        // Top apps enter (or refresh) tracking.
        for a in frameApps.prefix(maxTrackedApps) {
            if let i = slotIndex[a.identity.key] {
                slots[i].lastInTop = t
            } else {
                slotIndex[a.identity.key] = slots.count
                slots.append(AppSlot(key: a.identity.key, buffer: RingBuffer(capacity: appCapacity), lastInTop: t,
                                     seen: false))
            }
        }
        if slots.count > maxTrackedApps { evict(slots.count - maxTrackedApps) }

        // Points for every tracked app present in the frame (only tracked keys are looked up).
        for a in frameApps {
            guard let i = slotIndex[a.identity.key] else { continue }
            slots[i].seen = true
            slots[i].buffer.append(Entry(time: t, value: Self.metrics(of: a)))
        }
        for i in slots.indices where !slots[i].seen {
            slots[i].buffer.append(Entry(time: t, value: nil))
        }
    }

    /// Drops the `n` slots longest out of the top (swap-remove, index kept in sync).
    private mutating func evict(_ n: Int) {
        for _ in 0..<n {
            guard let victim = slots.indices.min(by: { slots[$0].lastInTop < slots[$1].lastInTop }) else { return }
            slotIndex[slots[victim].key] = nil
            let last = slots.count - 1
            if victim != last {
                slots.swapAt(victim, last)
                slotIndex[slots[victim].key] = victim
            }
            slots.removeLast()
        }
    }

    /// The app's `metrics` vector (filled by the engine's grouper); rebuilt from the typed fields only when a
    /// producer left it empty.
    static func metrics(of app: AppSample) -> AppMetrics {
        if app.metrics[.cpu] != nil || app.cpuPercent == nil { return app.metrics }
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
