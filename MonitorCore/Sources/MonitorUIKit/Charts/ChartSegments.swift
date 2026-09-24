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

    /// Index ranges of consecutive samples, in order.
    public static func runs(_ points: [SeriesPoint]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (i, p) in points.enumerated() {
            if isSample(p.value) {
                if start == nil { start = i }
            } else if let s = start {
                result.append(s..<i)
                start = nil
            }
        }
        if let s = start { result.append(s..<points.count) }
        return result
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
    /// in one pass with no intermediate arrays. Gaps break both.
    static func addSeries(_ points: [SeriesPoint], domain: ClosedRange<Double>, in size: CGSize,
                          line: inout Path, area: inout Path?, baseline: CGFloat? = nil, flipped: Bool = false) {
        let n = points.count
        guard n > 0 else { return }
        let base = baseline ?? (flipped ? 0 : size.height)
        var runStartX: CGFloat = 0
        var lastX: CGFloat = 0
        var inRun = false
        for i in 0..<n {
            let v = points[i].value
            if let v, v.isFinite {
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

    @inline(__always) private static func closeArea(_ area: inout Path, from lastX: CGFloat, to startX: CGFloat, base: CGFloat) {
        area.addLine(to: CGPoint(x: lastX, y: base))
        area.addLine(to: CGPoint(x: startX, y: base))
        area.closeSubpath()
    }
}
