import CoreGraphics
import Foundation
import MonitorModel
import SwiftUI

/// Chart geometry shared by every chart (DESIGN §2.3): even x over N samples, y clamped to a fixed domain,
/// gap rule (nil/NaN breaks line and area; never interpolate), and bounded point counts.
public enum ChartSegments {
    @inline(__always) static func isSample(_ v: Double?) -> Bool {
        guard let v else { return false }
        return v.isFinite
    }

    /// Live 1-s grid (ruling N2): nil runs of up to this many slots between two samples are bridged, so the 5-s
    /// background cadence (4 empty slots) draws as a line while a real pause (≥ 7 s) still breaks it.
    public static let liveBridgeSlots = 6

    /// Index ranges of runs, in order: each starts and ends on a sample. With `bridge` > 0, runs of at most `bridge`
    /// non-samples between two samples are bridged (the range then contains those non-sample indices — skip them).
    public static func runs(_ points: [SeriesPoint], bridge: Int = 0) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        var last = -1                     // last sample index in the open run
        for (i, p) in points.enumerated() where isSample(p.value) {
            if let s = start, i - last - 1 > bridge {
                result.append(s..<(last + 1))
                start = i
            } else if start == nil {
                start = i
            }
            last = i
        }
        if let s = start { result.append(s..<(last + 1)) }
        return result
    }

    /// Sample indices that form a run of their own (drawn as a dot, ruling N2).
    public static func loneSamples(_ points: [SeriesPoint], bridge: Int = 0) -> [Int] {
        runs(points, bridge: bridge).filter { $0.count == 1 }.map(\.lowerBound)
    }

    /// Number of drawable samples (DESIGN §3.15: fewer than 2 → "Collecting…").
    public static func sampleCount(_ points: [SeriesPoint]) -> Int {
        var n = 0
        for p in points where isSample(p.value) { n += 1 }
        return n
    }

    /// `x = i/(N−1)·w`.
    @inline(__always) public static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        count > 1 ? CGFloat(index) / CGFloat(count - 1) * width : 0
    }

    /// y-down position of `value` clamped to `domain`; a degenerate domain maps to the baseline.
    @inline(__always) public static func y(value: Double, domain: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return height }
        let f = (min(max(value, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span
        return height - CGFloat(f) * height
    }

    /// Min/max bucketing to at most `maxPoints` points, keeping extremes, time order and gaps
    /// (a bucket containing a gap emits a gap).
    public static func decimate(_ points: [SeriesPoint], maxPoints: Int) -> [SeriesPoint] {
        guard maxPoints >= 2, points.count > maxPoints else { return points }
        let buckets = maxPoints / 2
        var out: [SeriesPoint] = []
        out.reserveCapacity(buckets * 2)
        let n = points.count
        for b in 0..<buckets {
            let lo = b * n / buckets, hi = (b + 1) * n / buckets
            guard lo < hi else { continue }
            var minI = -1, maxI = -1, hasGap = false
            for i in lo..<hi {
                guard let v = points[i].value, v.isFinite else {
                    hasGap = true
                    continue
                }
                if minI < 0 || v < points[minI].value! { minI = i }
                if maxI < 0 || v > points[maxI].value! { maxI = i }
            }
            if hasGap || minI < 0 {
                out.append(SeriesPoint(time: points[lo].time, value: nil))
            } else if minI == maxI {
                out.append(points[minI])
            } else {
                out.append(points[min(minI, maxI)])
                out.append(points[max(minI, maxI)])
            }
        }
        return out
    }

    /// Appends the line (and optionally the closed area down to `baseline`) of `points` into the given paths,
    /// in one pass with no intermediate arrays. Gaps break both, except gaps of at most `bridge` slots between two
    /// samples (Live 1-s grid, `liveBridgeSlots`), which the line and area span.
    static func addSeries(_ points: [SeriesPoint], domain: ClosedRange<Double>, in size: CGSize,
                          line: inout Path, area: inout Path?, baseline: CGFloat? = nil, flipped: Bool = false,
                          bridge: Int = 0) {
        let n = points.count
        guard n > 0 else { return }
        let base = baseline ?? (flipped ? 0 : size.height)
        var runStartX: CGFloat = 0
        var lastX: CGFloat = 0
        var inRun = false
        var gap = 0                                   // non-samples since the last sample of the open run
        for i in 0..<n {
            let v = points[i].value
            if inRun, !isSample(v), bridge > 0 {
                gap += 1
                if gap <= bridge { continue }         // maybe bridged: decided at the next sample
                if area != nil { closeArea(&area!, from: lastX, to: runStartX, base: base) }
                inRun = false
                continue
            }
            if let v, v.isFinite {
                gap = 0
                let x = self.x(index: i, count: n, width: size.width)
                var y = self.y(value: v, domain: domain, height: size.height)
                if flipped { y = size.height - y }
                if inRun {
                    line.addLine(to: CGPoint(x: x, y: y))
                    area?.addLine(to: CGPoint(x: x, y: y))
                } else {
                    line.move(to: CGPoint(x: x, y: y))
                    if area != nil {
                        area!.move(to: CGPoint(x: x, y: base))
                        area!.addLine(to: CGPoint(x: x, y: y))
                    }
                    runStartX = x
                    inRun = true
                }
                lastX = x
            } else if inRun {
                if area != nil { closeArea(&area!, from: lastX, to: runStartX, base: base) }
                inRun = false
            }
        }
        if inRun, area != nil { closeArea(&area!, from: lastX, to: runStartX, base: base) }
    }

    /// Dots (circles of `radius`) for samples that form a run of their own — a lone point has no segment to draw
    /// (ruling N2). Fill the returned path in the line color.
    static func loneDots(_ points: [SeriesPoint], domain: ClosedRange<Double>, in size: CGSize, radius: CGFloat,
                         flipped: Bool = false, bridge: Int = 0) -> Path {
        var dots = Path()
        let n = points.count
        for i in loneSamples(points, bridge: bridge) {
            guard let v = points[i].value else { continue }
            var y = self.y(value: v, domain: domain, height: size.height)
            if flipped { y = size.height - y }
            let x = self.x(index: i, count: n, width: size.width)
            dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
        }
        return dots
    }

    @inline(__always) private static func closeArea(_ area: inout Path, from lastX: CGFloat, to startX: CGFloat, base: CGFloat) {
        area.addLine(to: CGPoint(x: lastX, y: base))
        area.addLine(to: CGPoint(x: startX, y: base))
        area.closeSubpath()
    }
}
