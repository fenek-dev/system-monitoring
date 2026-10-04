import AppKit
import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Pure rules of the Storage page chrome (DESIGN §3.17).
enum StorageChrome {
    /// Below this page width (1100 window → 880) the strip drops Purgeable and the children table drops Items:
    /// the 1-column table card is ~245 pt there and Name would be unreadable with all columns.
    static let compactBelow: CGFloat = 1000

    static func isCompact(pageWidth: CGFloat) -> Bool { pageWidth < compactBelow }

    /// "~" for home, otherwise the last path component (a volume keeps its user-facing name).
    static func rootLabel(_ root: ScanRoot) -> String {
        switch root {
        case .home: "~"
        case let .volume(_, name): name
        case let .folder(path): path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    /// Path with the home folder abbreviated to `~`.
    static func abbreviated(_ path: String, home: String) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func subtitle(root: ScanRoot) -> String {
        let home = if case let .home(path) = root { path } else { NSHomeDirectory() }
        return abbreviated(root.path, home: home)
    }
}

/// Which header button the page shows and whether it can be pressed.
struct StorageScanButton: Equatable {
    enum Kind: Equatable { case scan, rescan, cancel }

    var kind: Kind
    var enabled: Bool
    var help: String?

    static func make(phase: StorageModel.Phase, busy: StorageModel.BusyReason?, hasResult: Bool) -> StorageScanButton {
        if case .scanning = phase { return StorageScanButton(kind: .cancel, enabled: true, help: nil) }
        let blocked = busy == .cleaning
        return StorageScanButton(kind: hasResult ? .rescan : .scan, enabled: !blocked,
                                 help: blocked ? "Cleaning in progress" : nil)
    }
}

/// Header trailing content. Self-observing: the shell compares trailing views by id only, so Scan → Cancel only
/// reaches the header because this view reads the model itself.
struct StorageHeaderControls: View {
    @Environment(StorageModel.self) private var storage
    @Environment(\.now) private var now
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    /// Only a finished scan has a date: a partial tree is stamped with the wall clock while it is built.
    private var lastScan: Date? {
        switch storage.phase {
        case .ready, .scanning(hasPrevious: true):
            return storage.spaceMap.tree?.scanDate
        case .idle, .loadingCache, .failed, .scanning(hasPrevious: false):
            guard let summary = storage.summary, summary.root == storage.root else { return nil }
            return summary.scanDate
        }
    }

    var body: some View {
        let lastScan = lastScan
        let button = StorageScanButton.make(phase: storage.phase, busy: storage.busyReason, hasResult: lastScan != nil)
        HStack(spacing: TTSpace.x10) {
            rootChip
            if let lastScan { scannedLabel(lastScan) }
            scanButton(button)
        }
    }

    private var rootChip: some View {
        Menu {
            ForEach(Array(storage.availableRoots.enumerated()), id: \.offset) { _, root in
                Button(root.menuTitle) { select(root) }
            }
            Divider()
            Button("Choose Folder…") { chooseFolder() }
        } label: {
            // Drawn here rather than with `TTButtonStyle.chip`: a `Menu` adds its own bezel around a styled label.
            HStack(spacing: TTSpace.x4) {
                Text(StorageChrome.rootLabel(storage.root)).lineLimit(1)
                TTIcon(.chevronDown, size: 10, color: TTColor.textSecondary)
            }
            .font(TTFont.caption)
            .foregroundStyle(TTColor.textPrimary)
            .padding(.horizontal, TTSpace.x8)
            .frame(height: 22)
            .background(Capsule().fill(TTColor.bgElevated))
            .overlay(Capsule().strokeBorder(TTColor.borderPopover, lineWidth: TTStroke.hairline))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(storage.busyReason == .cleaning)
        .accessibilityLabel("Scan root")
    }

    @ViewBuilder private func scannedLabel(_ date: Date) -> some View {
        if isSnapshot {
            text(date, now: now ?? date)
        } else {
            TimelineView(.everyMinute) { context in text(date, now: context.date) }
        }
    }

    private func text(_ date: Date, now: Date) -> some View {
        Text(StorageFormat.scannedAgo(date, now: now, locale: locale, timeZone: timeZone))
            .font(TTFont.caption)
            .foregroundStyle(TTColor.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder private func scanButton(_ state: StorageScanButton) -> some View {
        switch state.kind {
        case .scan:
            Button("Scan") { storage.startScan() }
                .buttonStyle(.tt(.smallPrimary)).disabled(!state.enabled).help(state.help ?? "")
        case .rescan:
            Button("Rescan") { storage.startScan() }
                .buttonStyle(.tt(.smallSecondary)).disabled(!state.enabled).help(state.help ?? "")
        case .cancel:
            Button("Cancel") { storage.cancelScan() }
                .buttonStyle(.tt(.smallSecondary))
        }
    }

    private func select(_ root: ScanRoot) {
        Task { await storage.selectRoot(root) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(.folder(url.path))
    }
}

private extension ScanRoot {
    var menuTitle: String {
        switch self {
        case .home: "Home"
        case let .volume(_, name): name
        case .folder: StorageChrome.rootLabel(self)
        }
    }
}

/// Capacity · Used · Free · Purgeable · Reclaimable · Trash.
struct StorageStatStrip: View {
    let compact: Bool
    @Environment(LiveModel.self) private var live
    @Environment(StorageModel.self) private var storage

    private static let dataVolumePath = "/System/Volumes/Data"
    private static let notReported = "Not reported for this volume"

    /// The boot-volume sensor describes the user's Data volume only.
    private var volume: VolumeInfo? {
        switch storage.root {
        case .home: live.disk.bootVolume
        case let .volume(path, _): path == Self.dataVolumePath ? live.disk.bootVolume : nil
        case .folder: nil
        }
    }

    var body: some View {
        let v = volume
        let summary = storage.summary.flatMap { $0.root == storage.root ? $0 : nil }
        let used = v.map { $0.totalBytes - min($0.availableBytes, $0.totalBytes) }
        let reason = v == nil ? Self.notReported : nil
        var items: [TTStatStrip.Item] = [
            .init(id: "capacity", label: "Capacity", value: v.map { bytes($0.totalBytes) }, unavailableReason: reason),
            .init(id: "used", label: "Used", value: used.map { bytes($0) },
                  detail: v.flatMap { v in used.map { TTFormat.percent(v.totalBytes > 0 ? Double($0) / Double(v.totalBytes) : 0) + " of capacity" } },
                  unavailableReason: reason),
            .init(id: "free", label: "Free", value: v.map { bytes($0.availableBytes) }, unavailableReason: reason),
        ]
        if !compact {
            items.append(.init(id: "purgeable", label: "Purgeable", value: v?.purgeableBytes.map(bytes),
                               unavailableReason: reason ?? "Not reported"))
        }
        items.append(.init(id: "reclaimable", label: "Reclaimable", value: reclaimable(summary),
                           unavailableReason: "Scan your home folder first"))
        items.append(.init(id: "trash", label: "Trash", value: trash(summary), unavailableReason: "Not available"))
        return TTStatStrip(items)
    }

    private func bytes(_ b: UInt64) -> String { StorageFormat.bytes(b, provenance: .exact) }

    private func reclaimable(_ summary: StorageSummary?) -> String? {
        guard let summary, let b = summary.reclaimableBytes else { return nil }
        return StorageFormat.bytes(b, provenance: summary.provenance)
    }

    private func trash(_ summary: StorageSummary?) -> String? {
        guard let b = summary?.trashBytes else { return nil }
        return b == 0 ? "Empty" : StorageFormat.bytes(b, provenance: .exact)
    }
}
