import SwiftUI

/// DESIGN §2.2: one unpadded card of N equal columns; each cell VStack gap 3, padding 12×16:
/// label `caption` `textSecondary`; value `stat` (first cell in the category accent via `tint`);
/// optional sub `caption` `textTertiary`. Cells top-aligned; values never wrap (scale ≥ 0.8).
public struct TTStatStrip: View, Equatable {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var value: String?
        public var unit: String?
        public var detail: String?
        public var tint: Color?
        public var unavailableReason: String?

        public init(id: String, label: String, value: String?, unit: String? = nil, detail: String? = nil,
                    tint: Color? = nil, unavailableReason: String? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.unit = unit
            self.detail = detail
            self.tint = tint
            self.unavailableReason = unavailableReason
        }

        /// Value with its unit: "%" and "°…" attach directly, other units after a space. Unavailable drops the unit.
        var text: String? { TTUnit.join(value, unit) }
    }

    private let items: [Item]

    public init(_ items: [Item]) { self.items = items }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: TTSpace.x3) {
                    Text(item.label)
                        .font(TTFont.caption)
                        .foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                    // A hidden unscaled line fixes the `stat` line height; the value overlays it and may scale down
                    // (≥ 0.8) to the cell width without moving the sub-line.
                    Text("0").font(TTFont.stat).hidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            MetricValue(item.text, unavailableReason: item.unavailableReason, font: TTFont.stat)
                                .foregroundStyle(item.tint ?? TTColor.textPrimary)
                                .minimumScaleFactor(0.8)
                        }
                    if let detail = item.detail {
                        Text(detail)
                            .font(TTFont.caption)
                            .foregroundStyle(TTColor.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, TTSpace.statCellVertical)
                .padding(.horizontal, TTSpace.statCellHorizontal)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(TTStroke.hairline) // border outside the cells (≈ 80 + 2)
        .ttCardBackground()
    }
}
