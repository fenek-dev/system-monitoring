import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Which content the Space Map area shows for a phase (spec §4.5).
enum StorageContentState: Equatable {
    case blank
    case neverScanned
    case map
    case scanning(hasPrevious: Bool)
    case volumeRemoved
    case unreadable(String)

    static func make(phase: StorageModel.Phase, hasTree: Bool) -> StorageContentState {
        switch phase {
        case .idle: hasTree ? .map : .neverScanned
        case .loadingCache: .blank
        case .ready: .map
        case let .scanning(hasPrevious): .scanning(hasPrevious: hasPrevious)
        case let .failed(failure):
            switch failure {
            case .volumeRemoved: .volumeRemoved
            case let .rootUnreadable(reason), let .io(reason): .unreadable(reason)
            // A cancelled scan that left no finished tree is the same as never having scanned.
            case .cancelled: .neverScanned
            }
        }
    }
}

/// Never-scanned / failure screens: a message with the primary action below it.
struct StorageEmptyContent: View {
    let message: String
    var detail: String?
    var showsScan = true
    @Environment(StorageModel.self) private var storage

    var body: some View {
        VStack(spacing: TTSpace.x12) {
            if let detail {
                TTErrorState(message, detail: detail).frame(height: 40)
            } else {
                TTEmptyState(.empty(message)).frame(height: 18)
            }
            if showsScan {
                Button("Scan") { storage.startScan() }
                    .buttonStyle(.tt(.smallPrimary))
                    .disabled(!storage.canScan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Files, bytes and the path being read; reads only `ScanProgressState`, so a 10 Hz tick re-renders just this card.
struct ScanProgressCard: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let progress = storage.progress.progress
        TTCard(padding: TTSpace.x12, spacing: TTSpace.x6) {
            HStack(spacing: TTSpace.x12) {
                Text("Scanning…").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary)
                Text(summary(progress)).font(TTFont.body12).monospacedDigit().foregroundStyle(TTColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { storage.cancelScan() }.buttonStyle(.tt(.smallSecondary))
            }
            Text(progress?.currentPath ?? " ")
                .font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ progress: ScanProgress?) -> String {
        guard let progress else { return "Starting…" }
        let files = TTFormat.number(Double(progress.files))
        return "\(files) files · \(StorageFormat.bytes(progress.bytes, provenance: .exact))"
    }
}
