import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

/// LazyVStack, not NSTableView.
public struct TTTable<Row: Identifiable & Equatable>: View {
    public struct Column: Identifiable {
        public var id: String
        public var title: String
        public var width: ColumnWidth
        public var alignment: HorizontalAlignment
        public var sortKey: ((Row) -> Double?)?
        public var cell: (Row) -> AnyView

        public init(id: String, title: String, width: ColumnWidth, alignment: HorizontalAlignment = .leading,
                    sortKey: ((Row) -> Double?)? = nil, cell: @escaping (Row) -> AnyView) {
            self.id = id
            self.title = title
            self.width = width
            self.alignment = alignment
            self.sortKey = sortKey
            self.cell = cell
        }
    }

    public enum ColumnWidth { case flexible(min: CGFloat), fixed(CGFloat) }

    public init(rows: [Row], columns: [Column], selection: Binding<Row.ID?>, sort: Binding<(column: String, descending: Bool)>,
                rowMenu: ((Row) -> AnyView)? = nil, children: ((Row) -> [Row])? = nil) {}

    public var body: some View { EmptyView() }
}
