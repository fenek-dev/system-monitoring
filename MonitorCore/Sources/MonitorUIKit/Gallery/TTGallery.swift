import MonitorModel
import SwiftUI

/// Component gallery rendered by `telltale-render --gallery` / `--component <id>` for visual review
/// against the reference artboards. Deterministic sample data only.
@MainActor public enum TTGallery {
    public struct Item: Identifiable {
        public var id: String
        public var size: CGSize
        public var make: @MainActor () -> AnyView

        public init(id: String, size: CGSize, make: @escaping @MainActor () -> AnyView) {
            self.id = id
            self.size = size
            self.make = make
        }
    }

    public static var items: [Item] { GallerySamples.items }

    public static func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// Every item stacked on `bgWindow` with its id as a caption.
    public static func sheet(width: CGFloat = 1100) -> (view: AnyView, size: CGSize) {
        let all = items
        let height = all.reduce(CGFloat(20)) { $0 + $1.size.height + 36 }
        let view = VStack(alignment: .leading, spacing: 16) {
            ForEach(all) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.id).font(TTFont.micro).foregroundStyle(TTColor.textTertiary)
                    item.make().frame(width: item.size.width, height: item.size.height, alignment: .topLeading)
                }
            }
        }
        .padding(10)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(TTColor.bgWindow)
        return (AnyView(view), CGSize(width: width, height: height))
    }
}

/// Deterministic sample series for gallery and snapshot tests.
public enum SampleSeries {
    /// `count` points ending at `end`, 1 s apart; value = base + amp·(sin + small hash noise); nil where `gaps` says.
    public static func wave(count: Int = 60, base: Double, amplitude: Double, seed: Int = 1, end: Date = Date(timeIntervalSince1970: 1_790_000_000),
                            gaps: Range<Int>? = nil, clamp: ClosedRange<Double>? = nil) -> [SeriesPoint] {
        (0..<count).map { i in
            let t = end.addingTimeInterval(Double(i - count + 1))
            if let gaps, gaps.contains(i) { return SeriesPoint(time: t, value: nil) }
            let x = Double(i)
            var h = UInt64(truncatingIfNeeded: i &* 2_654_435_761 &+ seed &* 97)
            h ^= h >> 13
            let noise = Double(h % 1000) / 1000 - 0.5
            var v = base + amplitude * (0.55 * sin(x / 4.3 + Double(seed)) + 0.25 * sin(x / 1.7) + 0.5 * noise)
            if let clamp { v = min(max(v, clamp.lowerBound), clamp.upperBound) }
            return SeriesPoint(time: t, value: v)
        }
    }
}
