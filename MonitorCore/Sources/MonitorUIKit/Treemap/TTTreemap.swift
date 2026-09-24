import MonitorModel
import SwiftUI

/// DESIGN §2.28 time-travel treemap.
/// - Layout: `TreemapLayout.squarify` (Other last, bottom-right); each tile inset 1 pt (2-pt gutter, 1-pt outer
///   inset), radius 4.
/// - Fill: metric color @ 0.28 (hover 0.45); the top app (largest named share) gets a 1.5-pt inner stroke in the
///   same color. Other: `fillTrack`, "Other · {n} apps" in `caption` `textSecondary`, no value, not clickable.
/// - Label inset 8: name `body12Strong` (hidden below 60×28), value `caption` `textSecondary` (hidden under 40 tall).
/// - `animated`: frames animate `.easeInOut(0.25)`; false while scrubbing.
/// - Tooltip "{name} · {value} · {share}%"; click → `onSelect(key)`. Empty → "No data for this moment".
public struct TTTreemap: View, Equatable {
    let shares: [AppShare]
    let metric: AppMetric
    let animated: Bool
    let otherCount: Int?
    /// Only compared for presence in `==` (closures are called on the main actor).
    nonisolated(unsafe) let onSelect: ((AppKey) -> Void)?
    @Environment(\.unitPreferences) private var units

    public init(_ shares: [AppShare], metric: AppMetric, animated: Bool, onSelect: ((AppKey) -> Void)? = nil) {
        self.init(shares, metric: metric, animated: animated, otherCount: nil, onSelect: onSelect)
    }

    /// `otherCount`: number of apps aggregated into Other (label "Other · {n} apps").
    public init(_ shares: [AppShare], metric: AppMetric, animated: Bool, otherCount: Int?, onSelect: ((AppKey) -> Void)? = nil) {
        self.shares = shares
        self.metric = metric
        self.animated = animated
        self.otherCount = otherCount
        self.onSelect = onSelect
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.shares == b.shares && a.metric == b.metric && a.animated == b.animated && a.otherCount == b.otherCount
            && (a.onSelect == nil) == (b.onSelect == nil)
    }

    /// Value line for a tile ("812% CPU", "3.82 GB", "7.15 W").
    nonisolated static func valueText(_ value: Double, metric: AppMetric, units: UnitPreferences) -> String {
        switch metric {
        case .cpu: TTFormat.cpuPercentInteger(value) + " CPU"
        case .gpu: TTFormat.cpuPercentInteger(value) + " GPU"
        case .memory: TTFormat.bytes(UInt64(max(0, value)))
        case .netRx, .netTx: TTFormat.rate(value, units: units)
        case .diskRead, .diskWrite: TTFormat.diskRate(value)
        case .energy: TTFormat.appWatts(value)
        }
    }

    /// Label visibility thresholds (DESIGN §2.28).
    nonisolated static func showsName(_ size: CGSize) -> Bool { size.width >= 60 && size.height >= 28 }
    /// The value line needs 40 of height and a visible name (a lone truncated value reads as noise).
    nonisolated static func showsValue(_ size: CGSize) -> Bool { size.height >= 40 && showsName(size) }

    public var body: some View {
        let values = shares.map(\.value)
        let otherIndex = shares.firstIndex { $0.identity.key.kind == .other }
        let topIndex = shares.indices.filter { $0 != otherIndex && shares[$0].value > 0 }
            .max { shares[$0].value < shares[$1].value }
        if values.allSatisfy({ !($0 > 0) }) {
            TTEmptyState(.empty("No data for this moment"))
        } else {
            GeometryReader { geo in
                let rects = TreemapLayout.squarify(values, otherIndex: otherIndex, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(shares.indices, id: \.self) { i in
                        let r = rects[i].insetBy(dx: 1, dy: 1)
                        if r.width > 0, r.height > 0 {
                            Tile(share: shares[i], isOther: i == otherIndex, isTop: i == topIndex,
                                 color: TTColor.metric(metric),
                                 valueText: Self.valueText(shares[i].value, metric: metric, units: units),
                                 otherCount: otherCount, size: r.size, onSelect: i == otherIndex ? nil : onSelect)
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                        }
                    }
                }
                .animation(animated ? .easeInOut(duration: 0.25) : nil, value: rects)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private struct Tile: View {
        let share: AppShare
        let isOther: Bool
        let isTop: Bool
        let color: Color
        let valueText: String
        let otherCount: Int?
        let size: CGSize
        let onSelect: ((AppKey) -> Void)?
        @State private var hovering = false

        var name: String { share.identity.displayName }
        var sharePercent: String { TTFormat.number(share.fraction * 100, digits: 0) }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TTRadius.r4, style: .continuous)
            ZStack(alignment: .topLeading) {
                if isOther {
                    shape.fill(TTColor.fillTrack)
                } else {
                    shape.fill(color.opacity(hovering ? 0.45 : 0.28))
                    if isTop { shape.strokeBorder(color, lineWidth: 1.5) }
                }
                label.padding(8)
            }
            .contentShape(shape)
            .onHover { hovering = $0 && !isOther }
            .onTapGesture { onSelect?(share.identity.key) }
            .help(isOther ? otherLabel : "\(name) · \(valueText) · \(sharePercent)%")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isOther ? otherLabel : "\(name), \(valueText), \(sharePercent)%")
            .accessibilityAddTraits(onSelect != nil ? .isButton : [])
        }

        var otherLabel: String {
            if let otherCount { return "Other · \(TTFormat.count(otherCount)) apps" }
            return "Other"
        }

        @ViewBuilder var label: some View {
            if isOther {
                if TTTreemap.showsName(size) {
                    Text(otherLabel).font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: TTSpace.x2) {
                    if TTTreemap.showsName(size) {
                        Text(name).font(TTFont.body12Strong).foregroundStyle(TTColor.textPrimary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if TTTreemap.showsValue(size) {
                        Text(valueText).font(TTFont.caption).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                    }
                }
            }
        }
    }
}
