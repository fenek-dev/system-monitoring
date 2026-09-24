import SwiftUI

/// DESIGN §2.18 key-value list: rows HStack space-between gap 12, vertical padding 7, `body12`; label
/// `textSecondary`, value `textPrimary` right-aligned tabular; 1-pt `separator` under every row but the last.
/// A value may be mono (`mono11`, IPs) or unavailable ("—" + tooltip).
public struct TTKeyValueList: View, Equatable {
    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String?
        public var mono: Bool
        public var unavailableReason: String?
        public var estimated: Bool

        public init(_ label: String, _ value: String?, mono: Bool = false, unavailableReason: String? = nil,
                    estimated: Bool = false) {
            self.label = label
            self.value = value
            self.mono = mono
            self.unavailableReason = unavailableReason
            self.estimated = estimated
        }
    }

    let rows: [Row]

    public init(_ rows: [(String, String?)]) {
        self.rows = rows.map { Row($0.0, $0.1) }
    }

    public init(rows: [Row]) { self.rows = rows }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                HStack(spacing: TTSpace.x12) {
                    Text(row.label)
                        .font(TTFont.body12)
                        .foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    MetricValue(row.value, unavailableReason: row.unavailableReason, estimated: row.estimated,
                                font: row.mono ? TTFont.mono11 : TTFont.body12)
                        .foregroundStyle(TTColor.textPrimary)
                        .truncationMode(.middle)
                }
                .padding(.vertical, TTSpace.x7)
                .accessibilityElement(children: .combine)
                .overlay(alignment: .bottom) {
                    if i < rows.count - 1 { TTSeparator() }
                }
            }
        }
    }
}

/// 1-pt `separator` rule.
public struct TTSeparator: View {
    public init() {}
    public var body: some View {
        TTColor.separator.frame(height: TTStroke.hairline)
    }
}
