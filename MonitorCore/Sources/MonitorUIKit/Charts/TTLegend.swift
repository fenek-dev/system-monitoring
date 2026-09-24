import SwiftUI

/// DESIGN §2.11 legend: HStack gap 14; items HStack gap 6 of an 8×8 swatch (radius 2, series color; clear for a
/// "scale" item) and `caption` `textSecondary`. `swatchBorder` adds the 1-pt `borderSwatch` (Memory composition).
public struct TTLegend: View, Equatable {
    struct Item: Equatable {
        let id: String
        let label: String
        let color: Color
    }

    let items: [Item]
    let swatchBorder: Bool

    public init(_ series: [ChartSeries]) {
        self.init(series, swatchBorder: false)
    }

    public init(_ series: [ChartSeries], swatchBorder: Bool) {
        items = series.map { Item(id: $0.id, label: $0.label, color: $0.color) }
        self.swatchBorder = swatchBorder
    }

    /// Label/color pairs without series data.
    public init(items: [(label: String, color: Color)], swatchBorder: Bool = false) {
        self.items = items.enumerated().map { Item(id: "\($0.offset)", label: $0.element.label, color: $0.element.color) }
        self.swatchBorder = swatchBorder
    }

    public var body: some View {
        HStack(spacing: TTSpace.legendGap) {
            ForEach(items, id: \.id) { item in
                HStack(spacing: TTSpace.x6) {
                    RoundedRectangle(cornerRadius: TTRadius.r2, style: .continuous)
                        .fill(item.color)
                        .overlay {
                            if swatchBorder {
                                RoundedRectangle(cornerRadius: TTRadius.r2, style: .continuous)
                                    .strokeBorder(TTColor.borderSwatch, lineWidth: TTStroke.hairline)
                            }
                        }
                        .frame(width: 8, height: 8)
                    Text(item.label)
                        .font(TTFont.caption)
                        .foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize()
    }
}
