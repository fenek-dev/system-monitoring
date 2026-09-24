import Foundation
import MonitorModel

/// App episodes and swap growth (ARCHITECTURE §5.8).
///
/// App episode: one app keeps a metric at or above its threshold (cpu ≥ `cpuPercent`, gpu ≥ `gpuPercent`, each net
/// direction ≥ `netBps`, each disk direction ≥ `diskBps`); gaps up to `mergeGap` merge. Episodes shorter than
/// `minDuration` are dropped. An episode emits an open event (`end == nil`) when it reaches `minDuration` and a
/// closing event with the same id (end = last sample above the threshold) — the store upserts by id.
/// Swap growth: swap used grows by ≥ 1 GiB within 10 min → one `.swapGrowth` event (re-armed after swap shrinks
/// by 256 MiB from its peak).
public struct EventDetector: Sendable {
    private struct Key: Hashable, Sendable {
        var app: AppKey
        var metric: AppMetric
    }

    private struct Episode: Sendable {
        var id = UUID()
        var identity: AppIdentity
        var start: Date
        var lastAbove: Date
        var peak: Double
        var opened = false
    }

    static let swapGrowthBytes = Double(1 << 30)
    static let swapWindow: TimeInterval = 600
    static let swapRearmBytes = Double(256 << 20)

    public let config: EpisodeConfig
    private var episodes: [Key: Episode] = [:]
    private var swapSamples: [(time: Date, bytes: Double)] = []
    private var swapArmed = true
    private var swapPeakSinceFire = 0.0

    public init(config: EpisodeConfig = .init()) {
        self.config = config
    }

    public mutating func update(_ frame: SystemFrame) -> [HistoryEvent] {
        let now = frame.wallTime
        var events: [HistoryEvent] = []
        var above = Set<Key>()
        for a in frame.apps {
            for (metric, value, threshold) in thresholds(a) {
                guard let value, value >= threshold else { continue }
                let key = Key(app: a.identity.key, metric: metric)
                above.insert(key)
                if var e = episodes[key] {
                    e.lastAbove = now
                    e.peak = max(e.peak, value)
                    e.identity = a.identity
                    episodes[key] = e
                } else {
                    episodes[key] = Episode(identity: a.identity, start: now, lastAbove: now, peak: value)
                }
            }
        }
        let minDuration = config.minDuration.seconds, mergeGap = config.mergeGap.seconds
        for key in Array(episodes.keys) {
            guard var e = episodes[key] else { continue }
            if above.contains(key) {
                if !e.opened, now.timeIntervalSince(e.start) >= minDuration {
                    e.opened = true
                    events.append(event(e, key, end: nil))
                    episodes[key] = e
                }
            } else if now.timeIntervalSince(e.lastAbove) > mergeGap {
                if e.lastAbove.timeIntervalSince(e.start) >= minDuration { events.append(event(e, key, end: e.lastAbove)) }
                episodes[key] = nil
            }
        }
        if let swap = frame.memory.swapUsed { events += swapGrowth(Double(swap), at: now) }
        return events
    }

    /// Closes every open episode (pause, shutdown); only episodes of at least `minDuration` produce an event.
    public mutating func flush(at: Date) -> [HistoryEvent] {
        let minDuration = config.minDuration.seconds
        let out = episodes
            .filter { $0.value.lastAbove.timeIntervalSince($0.value.start) >= minDuration }
            .map { event($0.value, $0.key, end: $0.value.lastAbove) }
            .sorted { $0.start < $1.start }
        episodes.removeAll()
        swapSamples.removeAll()
        return out
    }

    // MARK: - Private

    private func thresholds(_ a: AppSample) -> [(AppMetric, Double?, Double)] {
        [(.cpu, a.cpuPercent, config.cpuPercent), (.gpu, a.gpuPercent, config.gpuPercent),
         (.netRx, a.netRxBps, config.netBps), (.netTx, a.netTxBps, config.netBps),
         (.diskRead, a.diskReadBps, config.diskBps), (.diskWrite, a.diskWriteBps, config.diskBps)]
    }

    private func event(_ e: Episode, _ key: Key, end: Date?) -> HistoryEvent {
        HistoryEvent(id: e.id, kind: .appEpisode, start: e.start, end: end, level: .calm, app: e.identity,
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

    private mutating func swapGrowth(_ bytes: Double, at now: Date) -> [HistoryEvent] {
        swapSamples.append((now, bytes))
        swapSamples.removeAll { now.timeIntervalSince($0.time) > Self.swapWindow }
        if !swapArmed {
            swapPeakSinceFire = max(swapPeakSinceFire, bytes)
            if swapPeakSinceFire - bytes >= Self.swapRearmBytes { swapArmed = true }
            return []
        }
        guard let low = swapSamples.min(by: { $0.bytes < $1.bytes }), low.time <= now,
              bytes - low.bytes >= Self.swapGrowthBytes else { return [] }
        swapArmed = false
        swapPeakSinceFire = bytes
        let grown = (bytes - low.bytes) / Double(1 << 30)
        return [HistoryEvent(kind: .swapGrowth, start: low.time, end: now, level: .elevated, peak: bytes,
                             label: String(format: "Swap grew by %.1f GB", grown))]
    }
}
