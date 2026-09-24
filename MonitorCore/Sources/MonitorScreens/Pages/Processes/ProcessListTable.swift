import AppKit
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
        .foregroundStyle(row.depth > 0 || row.isExitedResidual ? TTColor.textSecondary : TTColor.textPrimary)
        .italic(row.isExitedResidual)
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
        // Tooltips only on the hovered row (perf: no per-cell `.help` on ~900 rows); same texts as `MetricValue`.
        .overlay { if hovering { tooltips(widths) } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    // MARK: Cells (plain Text; "—" in `textTertiary`, DESIGN §3.15)

    @ViewBuilder private func cells(_ widths: [CGFloat]) -> some View {
        plain(row.pid.map { String($0) }, width: widths[0])
        Text(row.user ?? "")
            .foregroundStyle(TTColor.textSecondary)
            .frame(width: widths[1], alignment: .leading)
        plain(row.value(.cpu) == nil ? nil : TTFormat.cpuPercent(row.cpu, sign: false), width: widths[2])
        plain(row.value(.gpu) == nil ? nil : TTFormat.cpuPercent(row.gpu, sign: false), width: widths[3])
        plain(row.value(.memory) == nil ? nil : TTFormat.bytes(row.memory), width: widths[4])
        plain(row.value(.network) == nil ? nil : TTFormat.rateCell(row.network, units: units), width: widths[5])
        plain(row.value(.disk) == nil ? nil : TTFormat.diskRateCell(row.disk), width: widths[6])
        plain(row.value(.energy) == nil ? nil : TTFormat.appWatts(row.energy), width: widths[7])
    }

    private func plain(_ text: String?, width: CGFloat) -> some View {
        Group {
            if let text, text != TTFormat.unavailable {
                Text(text)
            } else {
                Text(TTFormat.unavailable).foregroundStyle(TTColor.textTertiary)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    /// The hovered row's tooltips, laid out like the cells: name/kind, "—" reasons, "Estimated".
    private func tooltips(_ widths: [CGFloat]) -> some View {
        HStack(spacing: TTSpace.tableCellGap) {
            HStack(spacing: 0) {
                // Keep the disclosure chevron clickable: the name tip starts after its slot.
                if showsDisclosure { tip(nil, width: 18) }
                tip(nameTooltip, width: nameWidth - (showsDisclosure ? 18 : 0))
            }
            tip(row.rowKind == .process && row.pid == nil ? "Coalition row: no single leader process" : nil,
                width: widths[0])
            tip(nil, width: widths[1])
            tip(cellTip(.cpu, estimated: row.cpuEstimated), width: widths[2])
            tip(cellTip(.gpu), width: widths[3])
            tip(cellTip(.memory), width: widths[4])
            tip(cellTip(.network), width: widths[5])
            tip(cellTip(.disk), width: widths[6])
            tip(cellTip(.energy, estimated: row.energyEstimated), width: widths[7])
        }
        .padding(.horizontal, TTSpace.tableRowInset)
    }

    @ViewBuilder private func tip(_ text: String?, width: CGFloat) -> some View {
        if let text {
            Color.clear.contentShape(Rectangle()).frame(width: width).help(text)
                .allowsHitTesting(true)
        } else {
            Color.clear.frame(width: width).allowsHitTesting(false)
        }
    }

    private func cellTip(_ column: ProcessColumn, estimated: Bool = false) -> String? {
        row.value(column) == nil ? row.reasons[column] : (estimated ? "Estimated" : nil)
    }

    private var nameTooltip: String? {
        switch row.rowKind {
        case .restrictedSummary: return "Owned by another user; counted in the coalition row"
        case .app, .process:
            if row.isExitedResidual { return "Processes that exited since the last sample (estimated)" }
            if let kind = row.kindLabel, row.depth == 0 { return "\(row.name) · \(kind)" }
            return row.name
        }
    }

    @ViewBuilder private var nameCell: some View {
        if row.rowKind == .restrictedSummary {
            HStack(spacing: 0) {
                // Aligned with child names: parent name + 28 (tile 20 + gap 8 + 28).
                Color.clear.frame(width: (showsDisclosure ? 18 : 0) + 56)
                Text(row.name).font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
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
                // The kind tag is never clipped and keeps its count ("App · 7 processes", DESIGN §3.12): the name
                // yields first (middle truncation, down to `minNameWidth`); only then does the tag drop to "App".
                // Chosen by measurement (monotonic in the available width; `kindFit`, tested).
                if let kind = row.kindLabel, row.depth == 0 {
                    let available = nameWidth - (showsDisclosure ? 18 : 0) - 28
                    let fit = Self.kindFit(name: Self.textWidth(row.name, size: 12),
                                           full: Self.textWidth(kind, size: 11),
                                           short: Self.textWidth(Self.shortKind(kind), size: 11),
                                           available: available)
                    nameAndKind(fit.keepsCount ? kind : Self.shortKind(kind), truncating: fit.truncatesName)
                } else if row.isExitedResidual {
                    // ICR-13: italic secondary, estimated (the hover tooltip explains).
                    Text(row.name).italic().foregroundStyle(TTColor.textSecondary).lineLimit(1)
                } else {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private func nameAndKind(_ kind: String, truncating: Bool) -> some View {
        HStack(spacing: TTSpace.x8) {
            // Always allowed to truncate (a measurement a pixel off must never push the tag out of the cell);
            // `truncating` only documents what `kindFit` expects.
            let _ = truncating
            Text(row.name).lineLimit(1).truncationMode(.middle)
            Text(kind).font(TTFont.caption).foregroundStyle(TTColor.textTertiary).lineLimit(1).fixedSize()
                .layoutPriority(1)
        }
    }

    /// Narrowest truncated name kept before the kind tag drops its count.
    nonisolated static let minNameWidth: CGFloat = 72

    /// Which kind label and whether the name truncates, for measured widths (gap 8). Monotonic: as `available`
    /// shrinks, the name first truncates (keeping the count) down to `minNameWidth` — or its own width if
    /// narrower — and only then the tag drops to its short form.
    nonisolated static func kindFit(name: CGFloat, full: CGFloat, short: CGFloat, available: CGFloat,
                                    gap: CGFloat = 8) -> (keepsCount: Bool, truncatesName: Bool) {
        if name + gap + full <= available { return (true, false) }
        if min(name, minNameWidth) + gap + full <= available { return (true, true) }
        return (false, name + gap + short > available)
    }

    /// Text width in the system font (body12 names, caption kinds); memoized — names and kinds rarely change.
    static func textWidth(_ s: String, size: CGFloat) -> CGFloat {
        let key = "\(size)|\(s)"
        if let w = widthCache[key] { return w }
        if widthCache.count > 4_096 { widthCache.removeAll(keepingCapacity: true) }
        let w = ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
        widthCache[key] = w
        return w
    }

    private static var widthCache: [String: CGFloat] = [:]

    /// "App · 7 processes" → "App".
    nonisolated static func shortKind(_ kind: String) -> String {
        kind.components(separatedBy: " · ").first ?? kind
    }

    @ViewBuilder private var disclosure: some View {
        if row.hasChildren && row.depth == 0 {
            // A tap target, not a Button (perf: no button style per row); still an accessible button.
            TTIcon(.chevronRight, size: 10)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: row.isExpanded)
                .frame(width: 12, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { onToggle(row.appKey) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
                .accessibilityAction { onToggle(row.appKey) }
        } else {
            Color.clear
        }
    }

}
