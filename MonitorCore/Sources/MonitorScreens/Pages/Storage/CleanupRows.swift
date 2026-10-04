import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// One table row: the model's line plus what the cells read besides it, so `TTTable`'s Equatable diffing redraws
/// just the row whose checkbox, In use badge or disclosure changed.
struct CleanupRow: Identifiable, Equatable {
    var line: CleanupLine
    var check: CheckState
    var inUse: Bool
    var expanded: Bool
    /// A clean is running: the checkbox is read-only (part of the row so it redraws when the run starts/ends).
    var locked: Bool

    var id: CleanupLineID { line.id }

    /// Why the row's checkbox is disabled, nil when it can be toggled.
    var disabledReason: String? {
        if locked { return "Cleaning…" }
        guard let item = line.item else { return nil }
        if item.ignored { return "Ignored" }
        return item.mode == .none ? "Shown for information; Warden doesn't delete this" : nil
    }
}

/// Items table of the Cleanup mode (DESIGN §3.17): checkbox · tile + name · size · tier · In use · last used.
/// `CleanupState.lines()` already holds the sorted, grouped, expanded rows, so the table gets them flat
/// (`sortsRows: false`) and the disclosure writes `cleanup.expanded`.
struct CleanupRows: View {
    let compact: Bool
    @Environment(StorageModel.self) private var storage
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var selection: CleanupLineID?
    @State private var hover: CleanupLineID?

    private var cleanup: CleanupState { storage.cleanup }

    private var locked: Bool { storage.busyReason == .cleaning }

    private var rows: [CleanupRow] {
        cleanup.lines().map { line in
            CleanupRow(line: line, check: cleanup.checkState(line.id),
                       inUse: line.item.map { cleanup.inUse.contains($0.id) || $0.runningApp } ?? false,
                       expanded: cleanup.expanded.contains(line.id), locked: locked)
        }
    }

    private var sort: Binding<(column: String, descending: Bool)> {
        Binding(
            get: {
                let key = switch cleanup.sort.key {
                case .size: "size"
                case .name: "name"
                case .lastUsed: "lastUsed"
                }
                return (key, !cleanup.sort.ascending)
            },
            set: { value in
                let key: CleanupSort.Key = switch value.column {
                case "name": .name
                case "lastUsed": .lastUsed
                default: .size
                }
                cleanup.sort = CleanupSort(key: key, ascending: !value.descending)
            })
    }

    var body: some View {
        TTTable(rows: rows, columns: columns, selection: $selection, sort: sort,
                rowMenu: { row in AnyView(menu(row)) },
                style: TTTableStyle(rowHeight: 34, childRowHeight: 34, sortsRows: false, headerSorts: true,
                                    showsSortIndicator: true, emptyMessage: "Nothing to clean here"),
                onDoubleClick: open, columnsVersion: compact ? 1 : 0, hover: $hover, onSpace: { row in
                    if row.disabledReason == nil { cleanup.toggle(row.id) }
                })
    }

    private func open(_ row: CleanupRow) {
        if let item = row.line.item {
            storage.reveal(path: item.path)
        } else {
            toggleExpanded(row.id)
        }
    }

    private func toggleExpanded(_ id: CleanupLineID) {
        if cleanup.expanded.contains(id) { cleanup.expanded.remove(id) } else { cleanup.expanded.insert(id) }
    }

    @ViewBuilder private func menu(_ row: CleanupRow) -> some View {
        if let item = row.line.item {
            Button("Reveal in Finder") { storage.reveal(path: item.path) }
        }
    }

    // MARK: - Columns

    private var columns: [TTTable<CleanupRow>.Column] {
        var list: [TTTable<CleanupRow>.Column] = [
            .init(id: "check", title: "", width: .fixed(TTTableCheckbox.columnWidth)) { row in AnyView(checkbox(row)) },
            .init(id: "name", title: "Name", width: .flexible(min: 120), sortKey: { _ in 0 }) { row in AnyView(name(row)) },
            .init(id: "size", title: "Size", width: .fixed(68), alignment: .trailing, sortKey: { _ in 0 }) { row in
                AnyView(size(row))
            },
            .init(id: "tier", title: "Tier", width: .fixed(compact ? 86 : 92)) { row in AnyView(tier(row)) },
            .init(id: "inUse", title: "", width: .fixed(72)) { row in AnyView(inUse(row)) },
        ]
        // The narrow layout drops last used first (spec §4.3).
        if !compact {
            list.append(.init(id: "lastUsed", title: "Last used", width: .fixed(92), alignment: .trailing,
                              sortKey: { _ in 0 }) { row in AnyView(lastUsed(row)) })
        }
        return list
    }

    private func checkbox(_ row: CleanupRow) -> some View {
        let state: TTTableCheckbox.CheckState = switch row.check {
        case .off: .off
        case .on: .on
        case .mixed: .mixed
        }
        return TTTableCheckbox(state, disabledReason: row.disabledReason) { cleanup.toggle(row.id) }
    }

    private func name(_ row: CleanupRow) -> some View {
        let line = row.line
        let isGroup = line.item == nil
        let child = line.depth > 0
        return HStack(spacing: 0) {
            if isGroup {
                Button { toggleExpanded(row.id) } label: {
                    TTIcon(.chevronRight, size: 10)
                        .rotationEffect(.degrees(row.expanded ? 90 : 0))
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.expanded ? "Collapse" : "Expand")
                .padding(.trailing, TTSpace.x6)
            } else if child {
                Color.clear.frame(width: 12 + TTSpace.x6)
            }
            tile(row).padding(.trailing, TTSpace.iconTextGapTable)
            Text(line.title).lineLimit(1).truncationMode(.tail)
            if isGroup {
                Text("\(line.childCount) items").font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                    .padding(.leading, TTSpace.x8).layoutPriority(-1)
            } else if line.item?.mode == .evict {
                Text("Remove Download").font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                    .padding(.leading, TTSpace.x8).layoutPriority(-1)
            }
        }
    }

    @ViewBuilder private func tile(_ row: CleanupRow) -> some View {
        let owner = row.line.owner ?? row.line.item?.owner
        let size: CGFloat = row.line.depth > 0 ? 16 : 20
        if let owner {
            TTAppTile(identity: AppIdentity(key: AppKey(kind: .app, id: owner.bundleID), displayName: owner.name,
                                            bundlePath: owner.appPath),
                      name: owner.name, size: size)
        } else {
            // Not owned by an app: a letter tile would suggest one, so show the storage glyph.
            TTIcon(.storage, size: size - 4).frame(width: size, height: size)
        }
    }

    private func size(_ row: CleanupRow) -> some View {
        Text(StorageFormat.bytes(row.line.bytes, provenance: row.line.provenance))
            .help(row.line.provenance == .exact ? "" : StorageFormat.estimateTooltip)
    }

    @ViewBuilder private func tier(_ row: CleanupRow) -> some View {
        if let item = row.line.item {
            if item.ignored {
                TTLink("Unignore") { storage.unignore(path: item.path) }
            } else {
                TTBadge(item.tier == .safe ? "Safe" : "Review", level: item.tier == .safe ? .calm : .elevated)
            }
        } else {
            Color.clear
        }
    }

    /// Empty cells keep a clear placeholder: a bare `EmptyView` drops its column frame and shifts the cells after it.
    @ViewBuilder private func inUse(_ row: CleanupRow) -> some View {
        if row.inUse { TTBadge("In use", level: .critical) } else { Color.clear }
    }

    private func lastUsed(_ row: CleanupRow) -> some View {
        guard let item = row.line.item else { return Text("") }
        let date = item.lastUsed
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        return Text(date.map { $0.formatted(style) } ?? TTFormat.unavailable).foregroundStyle(TTColor.textSecondary)
    }
}
