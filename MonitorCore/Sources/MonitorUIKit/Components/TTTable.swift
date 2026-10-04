import MonitorModel
import SwiftUI

/// DESIGN §2.20 data table (LazyVStack, not NSTableView).
/// Header: height 26 (28 Processes), padding 12, column gap 12, `captionMedium` `textSecondary`, 1-pt
/// `separator` below; clicking a sortable header sets the sort (active header `textPrimary` + chevron).
/// Body: 4 top padding, rows `body12` `textPrimary` tabular, height 34 (style), radius 6, zebra on odd rows,
/// hover `fillHover`, selection `rowSelected`. `children` rows (height 30) follow an expanded parent, share its
/// zebra parity and see `\.ttRowDepth == 1`. Right-click → `rowMenu`. ↑/↓ select, ←/→ collapse/expand.
/// Rows are Equatable (unchanged rows skip body per tick); only the hovered/selected row carries tooltips, the live
/// actions button and the context menu (`\.ttRowActive`).
/// Rows are sorted by the active column's `sortKey` (descending default, nil last, stable) unless
/// `style.sortsRows` is false (caller pre-sorted, e.g. `ProcessTableModel`).
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

    public enum ColumnWidth: Equatable, Sendable {
        /// Shares the remaining width equally with other flexible columns (weight 1), never below `min`.
        case flexible(min: CGFloat)
        case fixed(CGFloat)
        /// CSS `minmax(min, <weight>fr)`.
        case fraction(CGFloat, min: CGFloat)
    }

    let rows: [Row]
    let columns: [Column]
    @Binding var selection: Row.ID?
    @Binding var sort: (column: String, descending: Bool)
    let rowMenu: ((Row) -> AnyView)?
    let children: ((Row) -> [Row])?
    let style: TTTableStyle
    let onDoubleClick: ((Row) -> Void)?
    let columnsVersion: Int
    /// Cheap "has children" test; with it, `children` runs only for expanded rows.
    let hasChildren: ((Row) -> Bool)?
    /// Caller-owned hovered row; nil keeps hover local to each row.
    let hover: Binding<Row.ID?>?
    let onSpace: ((Row) -> Void)?
    @State private var expanded: Set<Row.ID> = []
    @Environment(\.isSnapshot) private var isSnapshot

    public init(rows: [Row], columns: [Column], selection: Binding<Row.ID?>, sort: Binding<(column: String, descending: Bool)>,
                rowMenu: ((Row) -> AnyView)? = nil, children: ((Row) -> [Row])? = nil) {
        self.init(rows: rows, columns: columns, selection: selection, sort: sort, rowMenu: rowMenu, children: children,
                  style: .standard, expandedByDefault: [], onDoubleClick: nil)
    }

    /// - Parameter columnsVersion: changes whenever state captured by the `cell` closures (sensor health, unit
    ///   settings) changes; rows are Equatable on their data, so without it such a change would leave stale cells.
    /// - Parameter hover: when given, the table writes the hovered row id here and each row's hover look follows it,
    ///   so a hover change re-evaluates only the row that lost and the row that gained it.
    /// - Parameter onSpace: Space on the selected (focused) row, e.g. toggling its `TTTableCheckbox`.
    public init(rows: [Row], columns: [Column], selection: Binding<Row.ID?>, sort: Binding<(column: String, descending: Bool)>,
                rowMenu: ((Row) -> AnyView)? = nil, children: ((Row) -> [Row])? = nil, style: TTTableStyle,
                expandedByDefault: Set<Row.ID> = [], onDoubleClick: ((Row) -> Void)? = nil, columnsVersion: Int = 0,
                hasChildren: ((Row) -> Bool)? = nil, hover: Binding<Row.ID?>? = nil, onSpace: ((Row) -> Void)? = nil) {
        self.columnsVersion = columnsVersion
        self.hasChildren = hasChildren
        self.hover = hover
        self.onSpace = onSpace
        self.rows = rows
        self.columns = columns
        _selection = selection
        _sort = sort
        self.rowMenu = rowMenu
        self.children = children
        self.style = style
        self.onDoubleClick = onDoubleClick
        _expanded = State(initialValue: expandedByDefault)
    }

    // MARK: - Pure logic (tested)

    struct Line: Identifiable {
        var id: Row.ID { row.id }
        let row: Row
        let depth: Int
        let parity: Int
        let hasChildren: Bool
        let isExpanded: Bool
    }

    nonisolated static func sorted(_ rows: [Row], key: ((Row) -> Double?)?, descending: Bool) -> [Row] {
        guard let key else { return rows }
        return TTSort.stable(rows, descending: descending, by: key)
    }

    /// `hasChildren`: cheap test; when given, `children` is called only for expanded rows (M11).
    nonisolated static func lines(_ rows: [Row], key: ((Row) -> Double?)?, descending: Bool, children: ((Row) -> [Row])?,
                                  expanded: Set<Row.ID>, hasChildren: ((Row) -> Bool)? = nil) -> [Line] {
        var out: [Line] = []
        out.reserveCapacity(rows.count)
        for (i, row) in sorted(rows, key: key, descending: descending).enumerated() {
            let kids: [Row]
            let has: Bool
            if let hasChildren {
                has = hasChildren(row)
                kids = has && expanded.contains(row.id) ? children?(row) ?? [] : []
            } else {
                kids = children?(row) ?? []
                has = !kids.isEmpty
            }
            let open = has && !kids.isEmpty && expanded.contains(row.id)
            out.append(Line(row: row, depth: 0, parity: i % 2, hasChildren: has, isExpanded: open))
            if open {
                for kid in sorted(kids, key: key, descending: descending) {
                    out.append(Line(row: kid, depth: 1, parity: i % 2, hasChildren: false, isExpanded: false))
                }
            }
        }
        return out
    }

    nonisolated static func columnWidths(_ widths: [ColumnWidth], available: CGFloat, gap: CGFloat) -> [CGFloat] {
        let fixed = widths.reduce(CGFloat(0)) { acc, w in if case .fixed(let v) = w { acc + v } else { acc } }
        var remaining = max(0, available - fixed - gap * CGFloat(max(0, widths.count - 1)))
        func weight(_ w: ColumnWidth) -> CGFloat {
            switch w {
            case .fixed: 0
            case .flexible: 1
            case .fraction(let f, _): f
            }
        }
        func minimum(_ w: ColumnWidth) -> CGFloat {
            switch w {
            case .fixed(let v): v
            case .flexible(let m), .fraction(_, let m): m
            }
        }
        var result = widths.map { w -> CGFloat in if case .fixed(let v) = w { v } else { 0 } }
        var open = Set(widths.indices.filter { weight(widths[$0]) > 0 })
        // Columns whose share falls below their minimum get the minimum; redistribute the rest.
        while !open.isEmpty {
            let total = open.reduce(CGFloat(0)) { $0 + weight(widths[$1]) }
            let pinned = open.filter { remaining * weight(widths[$0]) / total < minimum(widths[$0]) }
            if pinned.isEmpty {
                for i in open { result[i] = remaining * weight(widths[i]) / total }
                break
            }
            for i in pinned {
                result[i] = minimum(widths[i])
                remaining = max(0, remaining - result[i])
                open.remove(i)
            }
        }
        return result
    }

    nonisolated static func moved(selection: Row.ID?, in ids: [Row.ID], by delta: Int) -> Row.ID? {
        guard !ids.isEmpty else { return selection }
        guard let selection, let i = ids.firstIndex(of: selection) else { return delta > 0 ? ids.first : ids.last }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }

    // MARK: - View

    private var activeColumn: Column? { columns.first { $0.id == sort.column } }

    public var body: some View {
        let lines = style.sortsRows
            ? Self.lines(rows, key: activeColumn?.sortKey, descending: sort.descending, children: children, expanded: expanded,
                         hasChildren: hasChildren)
            : Self.lines(rows, key: nil, descending: true, children: children, expanded: expanded, hasChildren: hasChildren)
        GeometryReader { geo in
            let widths = Self.columnWidths(columns.map(\.width), available: geo.size.width - 2 * TTSpace.tableRowInset,
                                           gap: TTSpace.tableCellGap)
            VStack(alignment: .leading, spacing: 0) {
                header(widths: widths)
                if lines.isEmpty {
                    Text(style.emptyMessage)
                        .font(TTFont.body12)
                        .foregroundStyle(TTColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                } else if isSnapshot || !style.scrolls {
                    VStack(spacing: style.rowSpacing) { rowViews(lines, widths: widths) }
                        .padding(.top, TTSpace.x4)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: style.rowSpacing) { rowViews(lines, widths: widths) }
                            .padding(.top, TTSpace.x4)
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1, lines) }
        .onKeyPress(.downArrow) { move(1, lines) }
        .onKeyPress(.leftArrow) { setExpanded(false) }
        .onKeyPress(.rightArrow) { setExpanded(true) }
        .onKeyPress(.space) { space(lines) }
    }

    private func space(_ lines: [Line]) -> KeyPress.Result {
        guard let onSpace, let selection, let line = lines.first(where: { $0.id == selection }) else { return .ignored }
        onSpace(line.row)
        return .handled
    }

    private func move(_ delta: Int, _ lines: [Line]) -> KeyPress.Result {
        selection = Self.moved(selection: selection, in: lines.map(\.id), by: delta)
        return .handled
    }

    private func setExpanded(_ open: Bool) -> KeyPress.Result {
        guard let selection else { return .ignored }
        if open { expanded.insert(selection) } else { expanded.remove(selection) }
        return .handled
    }

    private func header(widths: [CGFloat]) -> some View {
        HStack(spacing: TTSpace.tableCellGap) {
            ForEach(columns.indices, id: \.self) { i in
                let column = columns[i]
                let active = column.sortKey != nil && column.id == sort.column && style.showsSortIndicator
                HeaderCell(title: column.title, active: active, descending: sort.descending,
                           alignment: column.alignment, sortable: column.sortKey != nil && style.headerSorts) {
                    if sort.column == column.id {
                        sort = (column.id, !sort.descending)
                    } else {
                        sort = (column.id, true)
                    }
                }
                .frame(width: widths[i], alignment: Alignment(horizontal: column.alignment, vertical: .center))
            }
        }
        .padding(.horizontal, TTSpace.tableRowInset)
        .frame(height: style.headerHeight)
        .overlay(alignment: .bottom) { TTSeparator() }
    }

    @ViewBuilder private func rowViews(_ lines: [Line], widths: [CGFloat]) -> some View {
        ForEach(lines) { line in
            let id = line.row.id
            TableRow(line: line, columns: columns, widths: widths, selected: selection == id,
                     height: line.depth > 0 ? style.childRowHeight : style.rowHeight, columnsVersion: columnsVersion,
                     rowMenu: rowMenu, externalHover: hover.map { $0.wrappedValue == id },
                     setHover: hover.map { hover in
                         { inside in
                             if inside { hover.wrappedValue = id } else if hover.wrappedValue == id { hover.wrappedValue = nil }
                         }
                     })
                .equatable()
                .environment(\.ttRowDepth, line.depth)
                .environment(\.ttRowDisclosure, line.hasChildren
                    ? TTRowDisclosure(hasChildren: true, isExpanded: line.isExpanded, toggle: { toggle(id) }) : nil)
                // Plain (non-simultaneous) tap gestures on the row: a control inside a cell (the checkbox) has
                // priority and consumes its clicks, while clicks on cell text fall through to the row. A layer
                // behind the cells never saw clicks on text (hit-tested first), so rows could not be selected.
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onDoubleClick?(line.row) }
                .onTapGesture { selection = id }
                .accessibilityAddTraits(selection == id ? [.isSelected] : [])
                .accessibilityAction { selection = id }
                .modifier(OpenAccessibilityAction(open: onDoubleClick.map { open in { open(line.row) } }))
        }
    }

    /// VoiceOver "Open" for tables with a double-click action (M13).
    private struct OpenAccessibilityAction: ViewModifier {
        let open: (() -> Void)?
        func body(content: Content) -> some View {
            if let open { content.accessibilityAction(named: "Open", open) } else { content }
        }
    }

    private func toggle(_ id: Row.ID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private struct HeaderCell: View {
        let title: String
        let active: Bool
        let descending: Bool
        let alignment: HorizontalAlignment
        let sortable: Bool
        let action: () -> Void

        var body: some View {
            let label = HStack(spacing: TTSpace.x4) {
                Text(title).font(TTFont.captionMedium).lineLimit(1)
                    .foregroundStyle(active ? TTColor.textPrimary : TTColor.textSecondary)
                if active {
                    TTIcon(.chevronDown, size: 10, color: TTColor.textPrimary).rotationEffect(.degrees(descending ? 0 : 180))
                }
            }
            if sortable {
                Button(action: action) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private struct TableRow: View, Equatable {
        /// Row types are caller-defined (not necessarily Sendable); rows are only built and compared on the main
        /// actor by SwiftUI's `.equatable()` diffing.
        nonisolated(unsafe) let line: Line
        let columns: [Column]
        let widths: [CGFloat]
        let selected: Bool
        let height: CGFloat
        /// Caller's version of state the cell closures capture (health, units): part of `==`, so such a change
        /// redraws rows whose data did not change (M2).
        let columnsVersion: Int
        /// Not part of `==` (a new closure each table body must not re-evaluate unchanged rows).
        let rowMenu: ((Row) -> AnyView)?
        /// Hover from the table's `hover` binding (nil: the row tracks its own). Part of `==`, so a hover change
        /// re-evaluates just the two rows whose flag flipped.
        let externalHover: Bool?
        /// Not part of `==`, like `rowMenu`.
        let setHover: ((Bool) -> Void)?
        @State private var localHover = false
        @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

        private var hovering: Bool { externalHover ?? localHover }

        nonisolated static func == (a: Self, b: Self) -> Bool {
            a.line.row == b.line.row && a.line.depth == b.line.depth && a.line.parity == b.line.parity
                && a.line.isExpanded == b.line.isExpanded && a.line.hasChildren == b.line.hasChildren
                && a.selected == b.selected && a.widths == b.widths && a.height == b.height
                && a.columnsVersion == b.columnsVersion && a.externalHover == b.externalHover
        }

        /// Hovered or selected (or VoiceOver on): the only rows that carry tooltips, the live actions button and
        /// the context menu (W5c pattern, U-M1).
        private var active: Bool { hovering || selected || voiceOver }

        var fill: Color {
            if selected { return TTColor.rowSelected }
            return line.parity == 1 ? TTColor.fillZebra : .clear
        }

        var body: some View {
            HStack(spacing: TTSpace.tableCellGap) {
                ForEach(columns.indices, id: \.self) { i in
                    columns[i].cell(line.row)
                        .font(TTFont.body12)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(line.depth > 0 ? TTColor.textSecondary : TTColor.textPrimary)
                        .frame(width: widths[i], alignment: Alignment(horizontal: columns[i].alignment, vertical: .center))
                }
            }
            .padding(.horizontal, TTSpace.tableRowInset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous).fill(fill)
                    .overlay {
                        if hovering && !selected {
                            RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous).fill(TTColor.fillHover)
                        }
                    }
            )
            .onHover { inside in
                if let setHover { setHover(inside) } else { localHover = inside }
            }
            .environment(\.ttRowActive, active)
            .contextMenu { if active, let rowMenu { rowMenu(line.row) } }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The one table sort (M10): by `key`, stable (ties keep input order), nil and non-finite keys last in both directions.
public enum TTSort {
    public static func stable<T>(_ items: [T], descending: Bool = true, by key: (T) -> Double?) -> [T] {
        items.enumerated()
            .map { (i: $0.offset, k: key($0.element).flatMap { $0.isFinite ? $0 : nil }, v: $0.element) }
            .sorted { a, b in
                switch (a.k, b.k) {
                case let (x?, y?): x != y ? (descending ? x > y : x < y) : a.i < b.i
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): a.i < b.i
                }
            }
            .map(\.v)
    }
}

/// Table metrics per page (DESIGN §2.20: header 26/28; rows 34, 32 Disk, 28 Sensors/connections; child 30).
public struct TTTableStyle: Sendable, Equatable {
    public var headerHeight: CGFloat
    public var rowHeight: CGFloat
    public var childRowHeight: CGFloat
    public var rowSpacing: CGFloat
    public var sortsRows: Bool
    public var headerSorts: Bool
    public var showsSortIndicator: Bool
    public var scrolls: Bool
    public var emptyMessage: String

    public init(headerHeight: CGFloat = 26, rowHeight: CGFloat = 34, childRowHeight: CGFloat = 30, rowSpacing: CGFloat = 0,
                sortsRows: Bool = true, headerSorts: Bool = false, showsSortIndicator: Bool = false, scrolls: Bool = true,
                emptyMessage: String = "No processes") {
        self.headerHeight = headerHeight
        self.rowHeight = rowHeight
        self.childRowHeight = childRowHeight
        self.rowSpacing = rowSpacing
        self.sortsRows = sortsRows
        self.headerSorts = headerSorts
        self.showsSortIndicator = showsSortIndicator
        self.scrolls = scrolls
        self.emptyMessage = emptyMessage
    }

    /// Fixed-sorted tables (Overview, CPU, GPU, Power…): header 26, rows 34.
    public static let standard = TTTableStyle()
    /// Processes: header 28, row gap 1, header click sets the sort binding (active indicator shown); rows are NOT
    /// re-sorted by the table — `ProcessTableModel` owns sorting and passes pre-sorted rows.
    public static let processes = TTTableStyle(headerHeight: 28, rowSpacing: 1, sortsRows: false, headerSorts: true,
                                               showsSortIndicator: true)
    public static let disk = TTTableStyle(rowHeight: 32)
    public static let compact = TTTableStyle(rowHeight: 28)
}

/// Apps-mode disclosure slot (DESIGN §3.12): 12 wide, `chevronRight` 10 rotated 90° when expanded
/// (`.easeInOut(0.15)`); empty slot for rows without children. Reads `\.ttRowDisclosure`.
public struct TTDisclosureButton: View {
    @Environment(\.ttRowDisclosure) private var disclosure

    public init() {}

    public var body: some View {
        Group {
            if let disclosure, disclosure.hasChildren {
                Button { disclosure.toggle() } label: {
                    TTIcon(.chevronRight, size: 10)
                        .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: disclosure.isExpanded)
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosure.isExpanded ? "Collapse" : "Expand")
            } else {
                Color.clear
            }
        }
        .frame(width: 12)
    }
}

/// DESIGN §2.20 name cell: HStack gap 8 of the app tile (20; 16 for child rows, indented so the child name starts
/// 28 right of the parent name) and the name (tail); optional kind label (`caption` `textTertiary`).
public struct TTNameCell: View {
    let tile: TTAppTile
    let name: String
    let kind: String?
    let disclosure: Bool
    @Environment(\.ttRowDepth) private var depth

    /// `disclosure`: include the Apps-mode 12-wide disclosure slot (+ gap 6).
    public init(identity: AppIdentity?, name: String, kind: String? = nil, disclosure: Bool = false) {
        tile = TTAppTile(identity: identity, name: name, size: 20)
        self.name = name
        self.kind = kind
        self.disclosure = disclosure
    }

    public var body: some View {
        HStack(spacing: 0) {
            if disclosure {
                TTDisclosureButton().padding(.trailing, TTSpace.x6)
            }
            if depth > 0 {
                // Child: name starts 28 right of the parent's name (parent: tile 20 + gap 8).
                Color.clear.frame(width: 20 + 8 + 28 - 16 - 8)
                TTAppTile(identity: tile.identity, name: name, size: 16)
                    .padding(.trailing, TTSpace.x8)
            } else {
                tile.padding(.trailing, TTSpace.iconTextGapTable)
            }
            Text(name).lineLimit(1).truncationMode(.tail)
            if let kind, depth == 0 {
                Text(kind).font(TTFont.caption).foregroundStyle(TTColor.textTertiary).lineLimit(1)
                    .padding(.leading, TTSpace.x8)
                    .layoutPriority(-1)
            }
        }
    }
}
