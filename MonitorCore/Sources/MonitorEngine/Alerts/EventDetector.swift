import Foundation
import MonitorModel

/// App episodes and swap growth (ARCHITECTURE §5.8).
///
/// App episode: one app keeps a metric at or above its threshold (cpu ≥ `cpuPercent`, gpu ≥ `gpuPercent`, each net
/// direction ≥ `netBps`, each disk direction ≥ `diskBps`); gaps up to `mergeGap` merge. Episodes shorter than
/// `minDuration` are dropped. An episode emits an open event (`end == nil`) when it reaches `minDuration` and a
/// closing event with the same id (end = last sample above the threshold) — the store upserts by id.
/// Swap growth: swap used grows by ≥ 1 GiB within 30 min → one `.swapGrowth` event (re-armed after swap shrinks
/// by 256 MiB from its peak).
/// Durations and windows run on the frame's monotonic `uptimeNs`; `wallTime` only stamps events. A sample gap longer
/// than max(merge gap, 2× nominal interval), on either clock (sleep/wake), closes every episode.
public struct EventDetector: Sendable {
    private struct Key: Hashable, Sendable {
        var app: AppKey
        var metric: AppMetric
    }

    private struct Episode: Sendable {
        var id = UUID()
        var identity: AppIdentity
        var start: Date                  // event timestamps (wall clock)
        var lastAbove: Date
        var startUp: Double              // durations (monotonic uptime, seconds)
        var lastAboveUp: Double
        var peak: Double
        var opened = false
    }

    static let swapGrowthBytes = Double(1 << 30)
    static let swapWindow: TimeInterval = 1_800        // DESIGN: "swap growth ≥ 1 GB within 30 min"
    static let swapRearmBytes = Double(256 << 20)

    public let config: EpisodeConfig
    private var episodes: [Key: Episode] = [:]
    private var swapSamples: [(time: Date, up: Double, bytes: Double)] = []
    private var last: (up: Double, wall: Date, nominal: Duration?)?
    private var swapArmed = true
    private var swapPeakSinceFire = 0.0

    public init(config: EpisodeConfig = .init()) {
        self.config = config
    }

    public mutating func update(_ frame: SystemFrame) -> [HistoryEvent] {
        let now = frame.wallTime
        let up = Double(frame.uptimeNs) / 1e9
        var events: [HistoryEvent] = []
        // A gap (sleep/wake, stall) longer than the merge gap / 2× the nominal cadence ends every episode.
        if let last {
            let nominal = max(frame.mode.interval ?? .seconds(1), last.nominal ?? .seconds(1))
            let allowed = max(2 * nominal.seconds, config.mergeGap.seconds)
            if up - last.up > allowed || now.timeIntervalSince(last.wall) > allowed {
                events += closeAll()
                swapSamples.removeAll()
            }
        }
        last = (up, now, frame.mode.interval)
        var above = Set<Key>()
        for a in frame.apps {
            for metric in Self.episodeMetrics {
                let (value, threshold) = reading(a, metric)
                guard let value, value >= threshold else { continue }
                let key = Key(app: a.identity.key, metric: metric)
                above.insert(key)
                if var e = episodes[key] {
                    e.lastAbove = now
                    e.lastAboveUp = up
                    e.peak = max(e.peak, value)
                    e.identity = a.identity
                    episodes[key] = e
                } else {
                    episodes[key] = Episode(identity: a.identity, start: now, lastAbove: now, startUp: up,
                                            lastAboveUp: up, peak: value)
                }
            }
        }
        let minDuration = config.minDuration.seconds, mergeGap = config.mergeGap.seconds
        for key in episodes.keys.sorted(by: Self.order) {           // deterministic event order within a frame
            guard var e = episodes[key] else { continue }
            if above.contains(key) {
                if !e.opened, up - e.startUp >= minDuration {
                    e.opened = true
                    events.append(event(e, key, end: nil))
                    episodes[key] = e
                }
            } else if up - e.lastAboveUp > mergeGap {
                if e.lastAboveUp - e.startUp >= minDuration { events.append(event(e, key, end: e.lastAbove)) }
                episodes[key] = nil
            }
        }
        if let swap = frame.memory.swapUsed { events += swapGrowth(Double(swap), at: now, up: up) }
        return events
    }

    /// Closes every open episode (pause, shutdown); only episodes of at least `minDuration` produce an event.
    /// `at` is not used: an episode ends at its last sample above the threshold.
    public mutating func flush(at: Date) -> [HistoryEvent] {
        let out = closeAll()
        swapSamples.removeAll()
        last = nil
        return out
    }

    private mutating func closeAll() -> [HistoryEvent] {
        let minDuration = config.minDuration.seconds
        let out = episodes.keys.sorted(by: Self.order).compactMap { key -> HistoryEvent? in
            guard let e = episodes[key], e.lastAboveUp - e.startUp >= minDuration else { return nil }
            return event(e, key, end: e.lastAbove)
        }
        episodes.removeAll()
        return out
    }

    private static func order(_ a: Key, _ b: Key) -> Bool {
        a.app.description != b.app.description ? a.app.description < b.app.description : a.metric.rawValue < b.metric.rawValue
    }

    // MARK: - Private

    /// Episode metrics, in a static list so the per-app loop allocates nothing.
    private static let episodeMetrics: [AppMetric] = [.cpu, .gpu, .netRx, .netTx, .diskRead, .diskWrite]

    private func reading(_ a: AppSample, _ metric: AppMetric) -> (value: Double?, threshold: Double) {
        switch metric {
        case .cpu: (a.cpuPercent, config.cpuPercent)
        case .gpu: (a.gpuPercent, config.gpuPercent)
        case .netRx: (a.netRxBps, config.netBps)
        case .netTx: (a.netTxBps, config.netBps)
        case .diskRead: (a.diskReadBps, config.diskBps)
        case .diskWrite: (a.diskWriteBps, config.diskBps)
        case .memory, .energy: (nil, .infinity)
        }
    }

    private func event(_ e: Episode, _ key: Key, end: Date?) -> HistoryEvent {
        HistoryEvent(id: e.id, kind: .appEpisode, start: e.start, end: end, level: .elevated, app: e.identity,
                     metric: key.metric, peak: e.peak, label: "\(e.identity.displayName): \(Self.noun(key.metric))")
    }

    private static func noun(_ m: AppMetric) -> String {
        switch m {
        case .cpu: "high CPU"
        case .gpu: "high GPU"
        case .netRx: "heavy download"
        case .netTx: "heavy upload"
        case .diskRead: "heavy disk reads"
        case .diskWrite: "heavy disk writes"
        case .memory: "high memory"
        case .energy: "high energy"
        }
    }

    private mutating func swapGrowth(_ bytes: Double, at now: Date, up: Double) -> [HistoryEvent] {
        swapSamples.append((now, up, bytes))
        swapSamples.removeAll { up - $0.up > Self.swapWindow }
        if !swapArmed {
            swapPeakSinceFire = max(swapPeakSinceFire, bytes)
            if swapPeakSinceFire - bytes >= Self.swapRearmBytes { swapArmed = true }
            return []
        }
        guard let low = swapSamples.min(by: { $0.bytes < $1.bytes }),
              bytes - low.bytes >= Self.swapGrowthBytes else { return [] }
        swapArmed = false
        swapPeakSinceFire = bytes
        swapSamples = [(now, up, bytes)]                 // the next event needs new growth from here
        let grown = (bytes - low.bytes) / Double(1 << 30)
        return [HistoryEvent(kind: .swapGrowth, start: low.time, end: now, level: .elevated, peak: bytes,
                             label: String(format: "Swap +%.1f GB", grown))]
    }
}
