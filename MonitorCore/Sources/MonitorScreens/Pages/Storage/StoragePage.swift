import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.17 Storage: FDA banner · stat strip · mode switch · Space Map or Cleanup, padding 20, gap 12.
public struct StoragePage: View {
    @Environment(StorageModel.self) private var storage
    @Environment(SettingsStore.self) private var settings
    @Environment(\.storageActions) private var actions
    @Environment(\.storageInitialMode) private var initialMode
    @Environment(\.now) private var now
    @State private var chosenMode: StorageMode?
    @State private var bannerDismissed = false

    public init() {}

    private var mode: StorageMode { storage.root.allowsCleanup ? (chosenMode ?? initialMode) : .spaceMap }

    /// What the classifier reads from settings; thresholds changing re-classifies the tree on screen.
    private struct Thresholds: Equatable {
        var large: UInt64
        var old: UInt64
    }

    private var thresholds: Thresholds { Thresholds(large: settings.storageLargeThreshold, old: settings.storageOldThreshold) }

    public var body: some View {
        GeometryReader { geo in
            let compact = StorageChrome.isCompact(pageWidth: geo.size.width)
            VStack(spacing: TTSpace.gridGap) {
                if storage.hasFullDiskAccess == false, !bannerDismissed { banner }
                StorageStatStrip(compact: compact)
                modeRow
                content(compact: compact, width: geo.size.width - 2 * TTSpace.pagePadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(TTSpace.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomTrailing) { CleanToastHost() }
        }
        // Subtitle hook must come after the trailing one: the later preference modifier wins the merge.
        .pageHeaderTrailing(id: "storage-controls") { StorageHeaderControls() }
        .background(StorageHeaderSubtitle())
        .task {
            await storage.applyClassifyOptions(settings.classifyOptions(now: now ?? Date()))
            await storage.pageDidAppear()
        }
        .onChange(of: thresholds) {
            Task { await storage.applyClassifyOptions(settings.classifyOptions(now: now ?? Date())) }
        }
        .onDisappear { storage.pageDidDisappear() }
    }

    private var banner: some View {
        TTAlertBanner(
            title: "Full Disk Access",
            message: "Some folders unreadable. Grant Full Disk Access for complete results.",
            level: .elevated,
            actions: [
                BannerAction(id: "open", title: "Open System Settings") { actions.openFDASettings() },
                BannerAction(id: "dismiss", title: "Dismiss") { bannerDismissed = true },
            ])
            // The banner carries its own outer margin (popover design); the page grid already spaces it.
            .padding(.top, -TTSpace.x2).padding(.horizontal, -TTSpace.x6).padding(.bottom, -TTSpace.x6)
    }

    private var modeRow: some View {
        HStack(spacing: TTSpace.x12) {
            TTSegmented(selection: Binding(
                get: { mode },
                set: { chosenMode = $0 }),
                        options: [(.spaceMap, "Space Map"), (.cleanup, "Cleanup")],
                        disabled: storage.root.allowsCleanup ? [] : [.cleanup])
            if !storage.root.allowsCleanup {
                Text("Cleanup is available for your home folder only.")
                    .font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Page states come first, in both modes: loading, scan progress and errors are about the scan, not the view.
    @ViewBuilder private func content(compact: Bool, width: CGFloat) -> some View {
        switch StorageContentState.make(phase: storage.phase, hasFinalTree: storage.spaceMap.overlay != nil) {
        case .blank:
            Color.clear
        case .neverScanned:
            StorageEmptyContent(message: "Scan your home folder to see what uses space.")
        case .map:
            modeContent(compact: compact, width: width)
        case .scanning(hasPrevious: false):
            VStack(spacing: TTSpace.gridGap) {
                ScanProgressCard()
                // Cleanup has nothing to list before the first scan finishes; the map shows the partial tree.
                if mode == .spaceMap { modeContent(compact: compact, width: width) } else { Color.clear }
            }
        case .scanning(hasPrevious: true):
            modeContent(compact: compact, width: width)
                .overlay(alignment: .top) { ScanProgressCard().frame(maxWidth: 520).padding(.top, TTSpace.x32) }
        case .volumeRemoved:
            StorageEmptyContent(message: "Volume was removed", showsScan: false)
        case let .unreadable(reason):
            StorageEmptyContent(message: "Couldn't scan this folder", detail: reason)
        }
    }

    @ViewBuilder private func modeContent(compact: Bool, width: CGFloat) -> some View {
        switch mode {
        case .cleanup: CleanupView(compact: compact)
        case .spaceMap: SpaceMapView(compact: compact, contentWidth: width)
        }
    }

}

/// Own view like Disk's: only it re-evaluates when the root changes.
private struct StorageHeaderSubtitle: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        Color.clear.pageHeader(subtitle: StorageChrome.subtitle(root: storage.root))
    }
}
