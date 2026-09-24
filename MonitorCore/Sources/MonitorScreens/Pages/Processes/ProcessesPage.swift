import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.12 Processes: list card (toolbar · table) above the inspector card, gap 12, padding 20.
/// Header: search field (220) replaces the range control; subtitle from the shell ("612 processes · …").
/// Keys: ↑/↓ select, ←/→ collapse/expand, Return toggles detail, ⌘⌫ force quit (confirmed), ⌘F search.
public struct ProcessesPage: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.processActions) private var actions
    @State private var table = ProcessTableModel()
    @State private var coordinator = ProcessActionCoordinator()
    @State private var inspector = AppInspectorModel()
    @State private var detailExpanded = false
    @FocusState private var searchFocused: Bool

    public init() {}

    public var body: some View {
        @Bindable var table = table
        let _ = table.update(from: live, mode: nav.processesMode)
        let _ = coordinator.actions = actions
        let selectedRow = table.row(for: nav.selection)
        let _ = inspector.record(selectedRow, at: live.lastUpdate)
        let availability = selectedRow.map {
            ProcessTableModel.availability(for: $0, serviceCanControl: $0.target.map(actions.canControl) ?? false)
        } ?? ProcessActionAvailability(canQuit: false, canForceQuit: false, disabledHelp: nil)

        VStack(spacing: TTSpace.gridGap) {
            listCard
                .frame(minHeight: Self.listMinHeight, maxHeight: .infinity)
            AppInspector(row: selectedRow, availability: availability, detailExpanded: detailExpanded,
                         onToggleDetail: toggleDetail,
                         onQuit: { target in Task { await coordinator.quit(target) } },
                         onForceQuit: { coordinator.requestForceQuit($0) },
                         model: inspector)
                .layoutPriority(1)
        }
        .padding(TTSpace.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: detailExpanded)
        .pageHeaderTrailing(id: "processes-search") {
            TTSearchField(text: $table.query, prompt: "Search processes")
                .focused($searchFocused)
                .accessibilityLabel("Search processes")
        }
        .environment(\.requestForceQuit, { [coordinator] target in coordinator.requestForceQuit(target) })
        .environment(\.onProcessActionResult, { [coordinator] target, result in
            coordinator.report(target, result, force: false)
        })
        .overlay { forceQuitDialog }
        .background { shortcuts(selectedRow, availability) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.leftArrow) { expand(false) }
        .onKeyPress(.rightArrow) { expand(true) }
        .onKeyPress(.return) {
            guard nav.selection != nil else { return .ignored }
            toggleDetail()
            return .handled
        }
        .onAppear { if nav.selection != nil { detailExpanded = true } }
        .onChange(of: live.appsVersion) {
            if nav.selection != nil, table.validated(nav.selection) == nil { nav.selection = nil }
        }
        .task(id: coordinator.toast?.id) {
            guard let id = coordinator.toast?.id else { return }
            try? await Task.sleep(for: ProcessActionCoordinator.toastDuration)
            coordinator.dismissToast(id)
        }
    }

    /// Never fewer than 5 rows when the inspector is expanded (DESIGN §3.12):
    /// padding 16×2 + border 2 + toolbar 28 + gap 12 + header 28 + 4 + 5 × 35.
    static let listMinHeight: CGFloat = 34 + 28 + 12 + 28 + 4 + 5 * 35

    // MARK: List card

    private var listCard: some View {
        VStack(alignment: .leading, spacing: TTSpace.gridGap) {
            toolbar
            ProcessListTable(
                lines: table.lines, emptyMessage: table.output.emptyMessage,
                showsDisclosure: nav.processesMode == .apps, selection: nav.selection,
                sort: table.sort, descending: table.descending,
                onSelect: { nav.selection = $0 },
                onSort: { column in
                    if table.sort == column { table.descending.toggle() } else {
                        table.sort = column
                        table.descending = true
                    }
                },
                onToggle: { key in withAnimation(.easeInOut(duration: 0.15)) { table.toggleExpanded(key) } },
                onDoubleClick: { row in
                    if let s = row.id.selection { nav.selection = s }
                    toggleDetail()
                })
        }
        .padding(TTSpace.cardPadding + TTStroke.hairline)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ttCardBackground()
    }

    private var toolbar: some View {
        let mode = Binding<NavigationModel.ProcessesMode>(
            get: { nav.processesMode },
            set: { new in
                guard new != nav.processesMode else { return }
                nav.selection = table.selection(nav.selection, convertedTo: new)
                nav.processesMode = new
            })
        let sort = Binding<ProcessColumn>(
            get: { table.sort },
            set: { new in
                if new != table.sort { table.descending = true }
                table.sort = new
            })
        return HStack(spacing: TTSpace.x12) {
            TTSegmented(selection: mode, options: [(.apps, "Apps"), (.processes, "Processes")])
                .accessibilityLabel("Show")
            Text("Sort by").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
            TTSegmented(selection: sort, options: ProcessColumn.allCases.map { ($0, $0.title) })
                .accessibilityLabel("Sort by")
            Group {
                if let toast = coordinator.toast {
                    Text(toast.text).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1).transition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            Text(table.countLabel).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                .monospacedDigit().lineLimit(1)
        }
        .frame(height: 28)
    }

    // MARK: Dialog & keys

    @ViewBuilder private var forceQuitDialog: some View {
        if let target = coordinator.pendingForceQuit {
            TTConfirmDialog(title: ProcessActionCoordinator.dialogTitle(target),
                            message: ProcessActionCoordinator.dialogMessage,
                            confirmTitle: "Force Quit",
                            onConfirm: { Task { await coordinator.confirmForceQuit() } },
                            onCancel: { coordinator.cancelForceQuit() })
        }
    }

    private func shortcuts(_ row: ProcessRow?, _ availability: ProcessActionAvailability) -> some View {
        ZStack {
            Button("Force Quit") {
                if let t = row?.target, availability.canForceQuit { coordinator.requestForceQuit(t) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func toggleDetail() { detailExpanded.toggle() }

    private func move(_ delta: Int) -> KeyPress.Result {
        nav.selection = table.moved(nav.selection, by: delta)
        return .handled
    }

    private func expand(_ open: Bool) -> KeyPress.Result {
        guard nav.processesMode == .apps, case .app(let key)? = nav.selection else { return .ignored }
        withAnimation(.easeInOut(duration: 0.15)) { table.setExpanded(key, open) }
        return .handled
    }
}
