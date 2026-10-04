import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.17 Cleanup: category list (1 of 3 columns) beside the items table (span 2), sticky footer below.
struct CleanupView: View {
    let compact: Bool
    @Environment(StorageModel.self) private var storage
    @Environment(\.presentConfirmDialog) private var presenter
    @Environment(\.now) private var now
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    /// What the last clean attempt found in use, for the footer until the selection changes.
    @State private var notice: (count: Int, checked: Set<Int32>)?
    @State private var confirming = false

    private static let footerHeight: CGFloat = 44
    private static let thresholds: [(UInt64, String)] = [
        (100_000_000, "100 MB"), (500_000_000, "500 MB"), (1_000_000_000, "1 GB"), (5_000_000_000, "5 GB"),
    ]

    private var cleanup: CleanupState { storage.cleanup }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: TTSpace.gridGap) {
                GridRow(columns: 3, spans: [1, 2], minHeight: max(300, geo.size.height - Self.footerHeight - TTSpace.gridGap)) {
                    categories
                    items
                }
                footer
            }
        }
        // The in-use badges are filled before the user ticks anything (spec §7.1 pre-check).
        .task(id: storage.root) { _ = await storage.recheckInUse() }
    }

    // MARK: - Categories

    private var categories: some View {
        TTCard(spacing: TTSpace.x4) {
            TTCardHeader("Categories") { EmptyView() }
            ForEach(CleanupCategory.allCases, id: \.self) { category in
                CategoryRow(category: category, total: cleanup.total(for: category),
                            unavailable: cleanup.totalsUnavailable, selected: cleanup.category == category) {
                    cleanup.category = category
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Items

    private var items: some View {
        TTCard(padding: 0, spacing: 0) {
            VStack(alignment: .leading, spacing: TTSpace.x8) {
                TTCardHeader(cleanup.category.cleanupTitle) {
                    Toggle("Show ignored", isOn: Bindable(cleanup).showIgnored)
                        .toggleStyle(.checkbox).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1).fixedSize()
                }
                // Own row: beside the title it does not fit the 1100-pt layout.
                if cleanup.category == .largeOld { thresholdControl }
            }
            .padding(TTSpace.cardPadding)
            CleanupRows(compact: compact)
        }
    }

    private var thresholdControl: some View {
        let selection = Binding<UInt64>(
            get: { settings?.storageLargeThreshold ?? storage.classifyOptions.largeBytes },
            set: { bytes in
                settings?.storageLargeThreshold = bytes
                var options = settings?.classifyOptions(now: now ?? Date()) ?? storage.classifyOptions
                options.largeBytes = bytes
                Task { await storage.applyClassifyOptions(options) }
            })
        return HStack(spacing: TTSpace.x8) {
            Text("At least").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
            TTSegmented(selection: selection, options: Self.thresholds, compact: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: TTSpace.x12) {
            footerStatus
            Spacer(minLength: 0)
            footerButton
        }
        .font(TTFont.body12)
        .padding(.horizontal, TTSpace.x4)
        .frame(height: Self.footerHeight)
        .overlay(alignment: .top) { TTSeparator() }
    }

    @ViewBuilder private var footerStatus: some View {
        if let progress = cleanup.cleanProgress {
            Text(progress.phase == .freeing ? "Freeing…" : "Cleaning \(progress.processed)/\(progress.total)…")
                .foregroundStyle(TTColor.textSecondary)
        } else {
            let bytes = cleanup.totalsUnavailable ? nil : cleanup.selectedBytes
            Text(StorageFormat.selection(bytes: bytes, provenance: cleanup.selectedProvenance,
                                         count: cleanup.selectedCount))
                .foregroundStyle(TTColor.textPrimary)
                .help(cleanup.selectedProvenance == .exact ? "" : StorageFormat.estimateTooltip)
            if let notice, notice.checked == cleanup.checked {
                Text("\(notice.count) \(notice.count == 1 ? "item" : "items") in use \(notice.count == 1 ? "was" : "were") unticked.")
                    .foregroundStyle(TTColor.textSecondary)
            }
        }
    }

    @ViewBuilder private var footerButton: some View {
        if let progress = cleanup.cleanProgress {
            if progress.phase == .detaching {
                Button("Cancel") { storage.cancelClean() }.buttonStyle(.tt(.smallSecondary))
            }
        } else {
            Button("Clean…") { startClean() }
                .buttonStyle(.tt(.smallPrimary))
                .disabled(cleanup.selectedCount == 0 || !storage.canClean || confirming)
        }
    }

    private func startClean() {
        confirming = true
        Task {
            let result = await CleanFlow.run(storage: storage, confirm: CleanFlow.ask(presenter))
            notice = result.newlyInUse > 0 ? (result.newlyInUse, cleanup.checked) : nil
            confirming = false
        }
    }
}

private struct CategoryRow: View {
    let category: CleanupCategory
    let total: CategoryTotal
    let unavailable: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: TTSpace.x4) {
                HStack {
                    Text(category.cleanupTitle).font(TTFont.body13).foregroundStyle(TTColor.textPrimary)
                    Spacer(minLength: TTSpace.x8)
                    Text(StorageFormat.bytes(unavailable ? nil : total.bytes, provenance: total.provenance))
                        .font(TTFont.body13Value).foregroundStyle(TTColor.textPrimary).monospacedDigit()
                }
                HStack(spacing: TTSpace.x6) {
                    if total.safeCount > 0 { TTBadge("Safe \(total.safeCount)", level: .calm) }
                    if total.reviewCount > 0 { TTBadge("Review \(total.reviewCount)", level: .elevated) }
                }
                if total.selectedBytes > 0 {
                    Text("\(StorageFormat.bytes(total.selectedBytes, provenance: total.provenance)) selected")
                        .font(TTFont.caption).foregroundStyle(TTColor.textSecondary).monospacedDigit()
                }
            }
            .padding(.horizontal, TTSpace.x10).padding(.vertical, TTSpace.x8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
                    .fill(selected ? TTColor.rowSelected : (hovering ? TTColor.fillHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private extension CleanupCategory {
    var cleanupTitle: String {
        switch self {
        case .userCaches: "User Caches"
        case .leftovers: "Leftovers"
        case .largeOld: "Large & Old"
        case .developer: "Developer"
        case .trash: "Trash"
        }
    }
}
