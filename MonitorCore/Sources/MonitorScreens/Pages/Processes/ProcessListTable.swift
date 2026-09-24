import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.12 process table, drawn to the §2.20 `TTTable` metrics (header 28, rows 34 / child 30, row gap 1,
/// padding 12, column gap 12, zebra, hover, `rowSelected`). It renders `ProcessTableModel` lines as they are:
/// the model owns sort, search and expansion (TTTable keeps expansion in private state), and rows stay
/// virtualized in a `LazyVStack` (~920 rows in the `restricted` scenario, ARCHITECTURE §7).
struct ProcessListTable: View {
    let lines: [ProcessRow]
    let emptyMessage: String
    let showsDisclosure: Bool
    let selection: NavigationModel.ProcessSelection?
    let sort: ProcessColumn
    let descending: Bool
    let onSelect: (NavigationModel.ProcessSelection) -> Void
    let onSort: (ProcessColumn) -> Void
    let onToggle: (AppKey) -> Void
    let onDoubleClick: (ProcessRow) -> Void

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.unitPreferences) private var units

    /// `minmax(0,2.2fr) 64 110 70 64 84 84 84 70` (DESIGN §3.12).
    static let fixedWidths: [CGFloat] = [64, 110, 70, 64, 84, 84, 84, 70]
    static let headers = ["Process", "PID", "User", "% CPU", "% GPU", "Memory", "Network", "Disk", "Energy"]
    static let sortColumns: [ProcessColumn?] = [nil, nil, nil, .cpu, .gpu, .memory, .network, .disk, .energy]

    static func nameWidth(total: CGFloat) -> CGFloat {
        let fixed = fixedWidths.reduce(0, +)
        let gaps = TTSpace.tableCellGap * CGFloat(fixedWidths.count)
        return max(0, total - 2 * TTSpace.tableRowInset - fixed - gaps)
    }

    var body: some View {
        GeometryReader { geo in
            let nameWidth = Self.nameWidth(total: geo.size.width)
            VStack(alignment: .leading, spacing: 0) {
                header(nameWidth: nameWidth)
                if lines.isEmpty {
                    Text(emptyMessage)
                        .font(TTFont.body12)
                        .foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                } else if isSnapshot {
                    // Only the rows that fit (plus one partial), clipped: deterministic and cheap.
                    let fit = Int((geo.size.height - 28 - 4) / 35) + 1
                    VStack(spacing: 1) { rows(Array(lines.prefix(max(0, fit))), nameWidth: nameWidth) }
                        .padding(.top, TTSpace.x4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 1) { rows(lines, nameWidth: nameWidth) }
                                .padding(.top, TTSpace.x4)
                        }
                        .scrollIndicators(.automatic)
                        .onChange(of: selection) { _, new in
                            guard let new else { return }
                            proxy.scrollTo(ProcessRowID(new))
                        }
                    }
                }
            }
        }
        .clipped()
    }

    private func header(nameWidth: CGFloat) -> some View {
        HStack(spacing: TTSpace.tableCellGap) {
            ForEach(Self.headers.indices, id: \.self) { i in
                let column = Self.sortColumns[i]
                let active = column == sort
                let label = HStack(spacing: TTSpace.x4) {
                    Text(Self.headers[i]).font(TTFont.captionMedium).lineLimit(1)
                        .foregroundStyle(active ? TTColor.textPrimary : TTColor.textSecondary)
                    if active {
                        TTIcon(.chevronDown, size: 10, color: TTColor.textPrimary)
                            .rotationEffect(.degrees(descending ? 0 : 180))
                    }
                }
                Group {
                    if let column {
                        Button { onSort(column) } label: { label }
                            .buttonStyle(.plain)
                            .help("Sort by \(column.title)")
                    } else {
                        label
                    }
                }
                .frame(width: i == 0 ? nameWidth : Self.fixedWidths[i - 1],
                       alignment: Self.alignment(i) == .leading ? .leading : .trailing)
            }
        }
        .padding(.horizontal, TTSpace.tableRowInset)
        .frame(height: 28)
        .overlay(alignment: .bottom) { TTSeparator() }
    }

    static func alignment(_ column: Int) -> HorizontalAlignment {
        column == 0 || column == 2 ? .leading : .trailing
    }

    @ViewBuilder private func rows(_ lines: [ProcessRow], nameWidth: CGFloat) -> some View {
        ForEach(lines) { row in
            let selected = row.id.selection != nil && row.id.selection == selection
            ProcessTableRow(row: row, nameWidth: nameWidth, selected: selected, showsDisclosure: showsDisclosure,
                            units: units, onToggle: onToggle)
                .equatable()
                .contentShape(Rectangle())
                .onTapGesture { if let s = row.id.selection { onSelect(s) } }
                .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(row) })
                .contextMenu {
                    if let target = row.target { TTRowActionsMenu(target: target) }
                }
                .id(row.id)
        }
    }
}

/// One line. Equatable so unchanged rows skip body evaluation on each 1-s frame.
struct ProcessTableRow: View, Equatable {
    let row: ProcessRow
    let nameWidth: CGFloat
    let selected: Bool
    let showsDisclosure: Bool
    let units: UnitPreferences
    /// Not part of `==`: a new closure each frame must not re-evaluate unchanged rows.
    let onToggle: (AppKey) -> Void
    @State private var hovering = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.nameWidth == b.nameWidth && a.selected == b.selected
            && a.showsDisclosure == b.showsDisclosure && a.units == b.units
    }

    private var fill: Color {
        if selected { return TTColor.rowSelected }
        return row.parity == 1 ? TTColor.fillZebra : .clear
    }

    var body: some View {
        let widths = ProcessListTable.fixedWidths
        HStack(spacing: TTSpace.tableCellGap) {
            nameCell.frame(width: nameWidth, alignment: .leading)
            if row.rowKind == .restrictedSummary {
                Spacer(minLength: 0)
            } else {
                cells(widths)
            }
        }
        .font(TTFont.body12)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(row.depth > 0 ? TTColor.textSecondary : TTColor.textPrimary)
        .padding(.horizontal, TTSpace.tableRowInset)
        .frame(height: row.depth > 0 ? 30 : 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous).fill(fill)
                .overlay {
                    if hovering && !selected && row.rowKind != .restrictedSummary {
                        RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous).fill(TTColor.fillHover)
                    }
                }
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func cells(_ widths: [CGFloat]) -> some View {
        MetricValue(row.pid.map { String($0) },
                    unavailableReason: row.pid == nil ? "Coalition row: no single leader process" : nil,
                    font: TTFont.body12)
            .frame(width: widths[0], alignment: .trailing)
        Text(row.user ?? "")
            .font(TTFont.body12)
            .foregroundStyle(TTColor.textSecondary)
            .frame(width: widths[1], alignment: .leading)
        metric(.cpu, TTFormat.cpuPercent(row.cpu, sign: false), estimated: row.cpuEstimated, width: widths[2])
        metric(.gpu, TTFormat.cpuPercent(row.gpu, sign: false), width: widths[3])
        metric(.memory, TTFormat.bytes(row.memory), width: widths[4])
        metric(.network, TTFormat.rateCell(row.network, units: units), width: widths[5])
        metric(.disk, TTFormat.diskRateCell(row.disk), width: widths[6])
        metric(.energy, TTFormat.appWatts(row.energy), estimated: row.energyEstimated, width: widths[7])
    }

    @ViewBuilder private var nameCell: some View {
        if row.rowKind == .restrictedSummary {
            HStack(spacing: 0) {
                // Aligned with child names: parent name + 28 (tile 20 + gap 8 + 28).
                Color.clear.frame(width: (showsDisclosure ? 18 : 0) + 56)
                Text(row.name).font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                    .help("Owned by another user; counted in the coalition row")
            }
        } else {
            // DESIGN §2.20/§3.12 name cell (same metrics as `TTNameCell`): disclosure slot 12 + 6, tile 20 (child: 16,
            // name 28 right of the parent's), name (keeps its width), kind label (shrinks first: the " · N processes"
            // part drops before any truncation).
            HStack(spacing: 0) {
                if showsDisclosure {
                    disclosure.frame(width: 12).padding(.trailing, TTSpace.x6)
                }
                if row.depth > 0 {
                    Color.clear.frame(width: 20 + 8 + 28 - 16 - 8)
                    TTAppTile(identity: row.identity, name: row.name, size: 16).padding(.trailing, TTSpace.x8)
                } else {
                    TTAppTile(identity: row.identity, name: row.name, size: 20).padding(.trailing, TTSpace.x8)
                }
                // The name yields (middle truncation keeps both ends of "com.apple.audio.Core-Audio-…-XPC");
                // the kind tag is never clipped: full "App · 7 processes" when it fits, else its short form.
                if let kind = row.kindLabel, row.depth == 0 {
                    ViewThatFits(in: .horizontal) {
                        nameAndKind(kind, truncating: false)
                        nameAndKind(Self.shortKind(kind), truncating: false)
                        nameAndKind(Self.shortKind(kind), truncating: true)
                    }
                    .help("\(row.name) · \(kind)")
                } else {
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                }
            }
        }
    }

    private func nameAndKind(_ kind: String, truncating: Bool) -> some View {
        HStack(spacing: TTSpace.x8) {
            if truncating {
                Text(row.name).lineLimit(1).truncationMode(.middle)
            } else {
                Text(row.name).lineLimit(1).fixedSize()
            }
            Text(kind).font(TTFont.caption).foregroundStyle(TTColor.textTertiary).lineLimit(1).fixedSize()
                .layoutPriority(1)
        }
    }

    /// "App · 7 processes" → "App".
    nonisolated static func shortKind(_ kind: String) -> String {
        kind.components(separatedBy: " · ").first ?? kind
    }

    @ViewBuilder private var disclosure: some View {
        if row.hasChildren && row.depth == 0 {
            Button { onToggle(row.appKey) } label: {
                TTIcon(.chevronRight, size: 10)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: row.isExpanded)
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear
        }
    }

    private func metric(_ column: ProcessColumn, _ text: String, estimated: Bool = false, width: CGFloat) -> some View {
        MetricValue(row.value(column) == nil ? nil : text, unavailableReason: row.reasons[column],
                    estimated: estimated, font: TTFont.body12)
            .frame(width: width, alignment: .trailing)
    }
}
