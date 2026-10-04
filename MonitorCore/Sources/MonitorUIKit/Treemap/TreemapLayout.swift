import CoreGraphics
import Foundation

/// DESIGN §2.28 squarified treemap (Bruls, Huizing & van Wijk 2000).
/// - Items are laid out in descending value order; rows go along the shorter side of the remaining rectangle, and an
///   item joins the current row while that brings the row's worst aspect ratio closer to 1.
/// - "Other" (`otherIndex`) is laid out **last**: it takes a final strip on the trailing edge of the container (right
///   when the container is at least as wide as tall, else bottom), so it lands in the bottom-right corner; the named
///   items fill the rest.
/// - Results are in input order; values ≤ 0 / NaN → `.zero`. Rects tile the container exactly (no gutter — the view
///   insets each tile by 1 pt).
public enum TreemapLayout {
    public static func squarify(_ values: [Double], otherIndex: Int?, in rect: CGRect) -> [CGRect] {
        layout(values, otherIndex: otherIndex, in: rect, presorted: false)
    }

    /// Same layout for input already in descending order (ties in input order): skips the sort, so it is O(n).
    public static func squarify(presorted values: [Double], otherIndex: Int?, in rect: CGRect) -> [CGRect] {
        layout(values, otherIndex: otherIndex, in: rect, presorted: true)
    }

    private static func layout(_ values: [Double], otherIndex: Int?, in rect: CGRect, presorted: Bool) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        guard !rect.isEmpty, rect.width > 0, rect.height > 0 else { return result }
        func valid(_ v: Double) -> Bool { v.isFinite && v > 0 }
        let total = values.reduce(0) { valid($1) ? $0 + $1 : $0 }
        guard total > 0 else { return result }

        var remaining = rect
        var named = values.indices.filter { valid(values[$0]) }
        if let o = otherIndex, values.indices.contains(o), valid(values[o]) {
            named.removeAll { $0 == o }
            if named.isEmpty {
                result[o] = rect
                return result
            }
            let fraction = values[o] / total
            if rect.width >= rect.height {
                let w = rect.width * fraction
                result[o] = CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height)
                remaining = CGRect(x: rect.minX, y: rect.minY, width: rect.width - w, height: rect.height)
            } else {
                let h = rect.height * fraction
                result[o] = CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
                remaining = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - h)
            }
        }

        // Descending by value; ties keep input order.
        if !presorted {
            named.sort { values[$0] != values[$1] ? values[$0] > values[$1] : $0 < $1 }
        }
        let namedTotal = named.reduce(0) { $0 + values[$1] }
        let scale = Double(remaining.width * remaining.height) / namedTotal
        let areas = named.map { values[$0] * scale }

        var start = 0
        while start < named.count {
            let side = Double(min(remaining.width, remaining.height))
            // Grow the row greedily.
            var end = start + 1
            var rowSum = areas[start]
            var minA = areas[start], maxA = areas[start]
            var worst = worstRatio(minA: minA, maxA: maxA, sum: rowSum, side: side)
            while end < named.count {
                let a = areas[end]
                let nextSum = rowSum + a
                let nextWorst = worstRatio(minA: min(minA, a), maxA: max(maxA, a), sum: nextSum, side: side)
                if nextWorst > worst { break }
                worst = nextWorst
                rowSum = nextSum
                minA = min(minA, a)
                maxA = max(maxA, a)
                end += 1
            }
            let isLast = end == named.count
            layoutRow(named[start..<end], areas: areas[start..<end], sum: rowSum, isLast: isLast, in: &remaining, into: &result)
            start = end
        }
        return result
    }

    /// Worst aspect ratio (≥ 1) of a row laid along `side`. Both ratio terms are monotone in the area, so the row's
    /// extremes (min/max area) give the same value as scanning every member, in O(1).
    private static func worstRatio(minA: Double, maxA: Double, sum: Double, side: Double) -> Double {
        guard sum > 0, side > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        var worst = 1.0
        if maxA > 0 { worst = max(worst, w2 * maxA / s2) }
        if minA > 0 { worst = max(worst, s2 / (w2 * minA)) }
        return worst
    }

    /// Places one row along the shorter side of `remaining` and shrinks it. The last row fills `remaining` exactly.
    private static func layoutRow(_ indices: ArraySlice<Int>, areas: ArraySlice<Double>, sum: Double, isLast: Bool,
                                  in remaining: inout CGRect, into result: inout [CGRect]) {
        let r = remaining
        if r.width >= r.height {
            // Vertical column on the left, items top → bottom.
            let w = isLast ? r.width : min(r.width, CGFloat(sum / Double(r.height)))
            var y = r.minY
            for (k, (i, a)) in zip(indices, areas).enumerated() {
                let last = k == indices.count - 1
                let h = last ? r.maxY - y : CGFloat(a / sum) * r.height
                result[i] = CGRect(x: r.minX, y: y, width: w, height: h)
                y += h
            }
            remaining = CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
        } else {
            // Horizontal row on top, items left → right.
            let h = isLast ? r.height : min(r.height, CGFloat(sum / Double(r.width)))
            var x = r.minX
            for (k, (i, a)) in zip(indices, areas).enumerated() {
                let last = k == indices.count - 1
                let w = last ? r.maxX - x : CGFloat(a / sum) * r.width
                result[i] = CGRect(x: x, y: r.minY, width: w, height: h)
                x += w
            }
            remaining = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
        }
    }

    /// max(w/h, h/w) over the non-empty rects (1 when none).
    public static func worstAspectRatio(_ rects: [CGRect]) -> Double {
        var worst = 1.0
        for r in rects where r.width > 0 && r.height > 0 {
            worst = max(worst, Double(max(r.width / r.height, r.height / r.width)))
        }
        return worst
    }
}
