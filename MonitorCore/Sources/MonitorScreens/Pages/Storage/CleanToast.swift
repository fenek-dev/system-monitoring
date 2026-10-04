import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Toast and sheet copy for a finished run.
enum CleanToastText {
    /// "Freed 1.2 GB · Moved 300 MB to Trash". Trashed bytes are still on disk until the Trash is emptied, so they
    /// never count as freed.
    static func make(_ report: CleanReport) -> String {
        let freed = report.freedBytes + report.evictedBytes
        var parts: [String] = []
        if freed > 0 { parts.append("Freed \(StorageFormat.bytes(freed, provenance: .exact))") }
        if report.trashedBytes > 0 {
            parts.append("Moved \(StorageFormat.bytes(report.trashedBytes, provenance: .exact)) to Trash")
        }
        let text = parts.isEmpty ? "Nothing was cleaned" : parts.joined(separator: " · ")
        return report.cancelled ? "Stopped. " + text : text
    }

    static func reason(_ reason: SkipReason) -> String {
        switch reason {
        case .denied: "Protected location"
        case .inUse: "In use"
        case .changedSinceScan: "Changed since the scan"
        case .notPermitted: "Not permitted"
        case .noTrash: "No Trash on this volume"
        case .stagingOtherVolume: "On another volume"
        case .vanished: "Already gone"
        case .rollbackCollision: "Original name taken, left in staging"
        case .cancelled: "Cancelled"
        case let .failed(message): "Failed: \(message)"
        }
    }
}

enum CleanToastActions {
    /// Confirm first, then empty. true = the run started.
    @MainActor
    static func emptyTrash(storage: StorageModel, confirm: ConfirmAsk) async -> Bool {
        let size = storage.summary?.trashBytes.map { " (\(StorageFormat.bytes($0, provenance: .exact)))" } ?? ""
        guard await confirm("Empty Trash?", "Permanently delete everything in the Trash\(size).", "Empty Trash") else {
            return false
        }
        return storage.emptyTrash()
    }
}

/// Page-level toast for a finished clean (DESIGN §3.12 with actions). Shows for any run that ends with a report except
/// the Undo / Empty Trash runs it starts itself.
struct CleanToastHost: View {
    private struct Presented: Equatable {
        var id: Int
        var text: String
        var trashed: Bool
        var undoID: UUID?
    }

    @Environment(StorageModel.self) private var storage
    @Environment(\.presentConfirmDialog) private var presenter
    @State private var toast: Presented?
    @State private var runs = 0
    @State private var showSkipped = false
    /// Set when this host started an Undo / Empty Trash: their reports are not clean results.
    @State private var ownRun = false

    var body: some View {
        Group {
            if let toast {
                CleanToastView(text: toast.text, actions: actions(for: toast))
                    .task(id: Timer(id: toast.id, pinned: showSkipped)) {
                        guard !showSkipped else { return }
                        try? await Task.sleep(for: TTToast.lifetime(hasUndo: toast.undoID != nil))
                        self.toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: toast)
        .onChange(of: storage.cleanup.lastReport) { _, report in
            guard let report else {
                toast = nil
                return
            }
            if ownRun {
                ownRun = false
                return
            }
            runs += 1
            toast = Presented(id: runs, text: CleanToastText.make(report), trashed: report.trashedBytes > 0,
                              undoID: report.undo?.id)
        }
        .sheet(isPresented: $showSkipped) { SkippedSheet(skipped: storage.cleanup.skipped) { showSkipped = false } }
    }

    /// The timer restarts (and is paused) with the sheet.
    private struct Timer: Equatable {
        var id: Int
        var pinned: Bool
    }

    private func actions(for toast: Presented) -> [TTToast.Action] {
        var list: [TTToast.Action] = []
        if !storage.cleanup.skipped.isEmpty { list.append(.show { showSkipped = true }) }
        if toast.trashed {
            list.append(.emptyTrash {
                Task {
                    let ask = CleanFlow.ask(presenter)
                    ownRun = true
                    if await CleanToastActions.emptyTrash(storage: storage, confirm: ask) {
                        self.toast = nil
                    } else {
                        ownRun = false
                    }
                }
            })
        }
        if let undoID = toast.undoID, storage.cleanup.lastUndo?.id == undoID {
            list.append(.undo {
                if storage.undoLast() {
                    ownRun = true
                    self.toast = nil
                }
            })
        }
        return list
    }
}

/// Toast chrome; shared with renders.
struct CleanToastView: View {
    let text: String
    let actions: [TTToast.Action]

    var body: some View {
        TTToast(text, actions: actions)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: TTRadius.r8).fill(TTColor.bgElevated))
    }
}

private struct SkippedSheet: View {
    let skipped: [(item: CleanupItem, reason: SkipReason)]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.x12) {
            Text("Not cleaned").font(TTFont.dialogTitle).foregroundStyle(TTColor.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: TTSpace.x8) {
                    ForEach(skipped, id: \.item.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: TTSpace.x12) {
                            Text(entry.item.name).font(TTFont.body12).foregroundStyle(TTColor.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(CleanToastText.reason(entry.reason)).font(TTFont.caption)
                                .foregroundStyle(TTColor.textSecondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.tt(.smallPrimary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(TTSpace.x16)
        .frame(width: 420)
    }
}
