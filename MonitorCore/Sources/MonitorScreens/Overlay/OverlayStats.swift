import Foundation
import MonitorModel

/// Rolling min / max / avg of one overlay metric (spec 2026-09-25 overlay §Stats).
public struct OverlayStats: Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var avg: Double

    public init(min: Double, max: Double, avg: Double) {
        self.min = min
        self.max = max
        self.avg = avg
    }
}

extension OverlayStats {
    /// Longest time one sample may stand for: the background cadence, so a pause or gap never dominates avg.
    static let maxWeight: TimeInterval = 5
    /// Weight of the newest sample (one overlay tick).
    static let lastWeight: TimeInterval = 1

    /// Non-nil samples in [now − window, now]; nil if fewer than 2. avg is time-weighted:
    /// each sample weighs the gap to the next non-nil sample, capped at 5 s; the last sample weighs 1 s.
    /// Gaps are excluded (never count as 0). `points` must be in time order (as `chartSeries` returns them).
    public static func compute(_ points: [SeriesPoint], window: Duration = .seconds(60), now: Date) -> OverlayStats? {
        let start = now.addingTimeInterval(-(window / .seconds(1)))
        var samples: [(time: Date, value: Double)] = []
        samples.reserveCapacity(points.count)
        for p in points {
            guard let v = p.value, v.isFinite, p.time >= start, p.time <= now else { continue }
            samples.append((p.time, v))
        }
        guard samples.count >= 2 else { return nil }

        var lo = samples[0].value, hi = samples[0].value
        var weighted = 0.0, total = 0.0
        for (i, s) in samples.enumerated() {
            lo = Swift.min(lo, s.value)
            hi = Swift.max(hi, s.value)
            let w = i + 1 < samples.count
                ? Swift.min(Swift.max(samples[i + 1].time.timeIntervalSince(s.time), 0), maxWeight)
                : lastWeight
            weighted += s.value * w
            total += w
        }
        return OverlayStats(min: lo, max: hi, avg: weighted / total)   // total ≥ lastWeight > 0
    }
}
