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

/// Toast state and lifetime, apart from the view so the timer and run bookkeeping are testable with a fake clock.
@MainActor @Observable
final class CleanToastController {
    struct Presented: Equatable {
        var id: Int
        var text: String
        var trashed: Bool
        var undoID: UUID?
    }

    /// What the view observes: a run is in flight, and the report it ended with (nil while running / interrupted).
    struct RunState: Equatable {
        var running: Bool
        var report: CleanReport?
    }

    private(set) var toast: Presented?
    private(set) var pinned = false
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private(set) var timer: Task<Void, Never>?
    @ObservationIgnored private var runs = 0
    /// An Undo / Empty Trash this controller started is in flight: its report is not a clean result.
    @ObservationIgnored private var ownRunActive = false

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func dismiss() {
        timer?.cancel()
        toast = nil
    }

    /// Call right after the model accepted an Undo / Empty Trash.
    func ownRunStarted() { ownRunActive = true }

    /// Call when a started own run was refused or declined, so no run is expected.
    func ownRunAbandoned() { ownRunActive = false }

    func runStateChanged(_ state: RunState) {
        if state.running {
            dismiss()
            return
        }
        // Any end of a run clears the own-run mark, with or without a report (an interrupted stream has none), so it
        // cannot swallow a later clean's toast.
        let own = ownRunActive
        ownRunActive = false
        guard !own, let report = state.report else { return }
        runs += 1
        toast = Presented(id: runs, text: CleanToastText.make(report), trashed: report.trashedBytes > 0,
                          undoID: report.undo?.id)
        arm()
    }

    /// The Show sheet is open: the toast stays until it closes, then gets its full lifetime again.
    func setPinned(_ value: Bool) {
        guard value != pinned else { return }
        pinned = value
        if value { timer?.cancel() } else { arm() }
    }

    private func arm() {
        timer?.cancel()
        guard let current = toast, !pinned else { return }
        let id = current.id
        let lifetime = TTToast.lifetime(hasUndo: current.undoID != nil)
        timer = Task { [sleep] in
            do { try await sleep(lifetime) } catch { return }
            // A newer toast or a pin may have replaced this timer after it woke.
            guard !Task.isCancelled, toast?.id == id, !pinned else { return }
            toast = nil
        }
    }
}

/// Page-level toast for a finished clean (DESIGN §3.12 with actions). Shows for any run that ends with a report except
/// the Undo / Empty Trash runs it starts itself.
struct CleanToastHost: View {
    @Environment(StorageModel.self) private var storage
    @Environment(\.presentConfirmDialog) private var presenter
    @State private var controller = CleanToastController()
    @State private var showSkipped = false

    var body: some View {
        Group {
            if let toast = controller.toast {
                CleanToastView(text: toast.text, actions: actions(for: toast))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: controller.toast)
        .onChange(of: CleanToastController.RunState(running: storage.cleanup.cleanProgress != nil,
                                                    report: storage.cleanup.lastReport)) { _, state in
            controller.runStateChanged(state)
        }
        .onChange(of: showSkipped) { _, open in controller.setPinned(open) }
        .sheet(isPresented: $showSkipped) { SkippedSheet(skipped: storage.cleanup.skipped) { showSkipped = false } }
    }

    private func actions(for toast: CleanToastController.Presented) -> [TTToast.Action] {
        var list: [TTToast.Action] = []
        if !storage.cleanup.skipped.isEmpty { list.append(.show { showSkipped = true }) }
        if toast.trashed {
            list.append(.emptyTrash {
                Task {
                    let ask = CleanFlow.ask(presenter)
                    // Marked before the run can start; the model reports the run's end either way.
                    controller.ownRunStarted()
                    if await CleanToastActions.emptyTrash(storage: storage, confirm: ask) {
                        controller.dismiss()
                    } else {
                        controller.ownRunAbandoned()
                    }
                }
            })
        }
        if let undoID = toast.undoID, storage.cleanup.lastUndo?.id == undoID {
            list.append(.undo {
                controller.ownRunStarted()
                if storage.undoLast() {
                    controller.dismiss()
                } else {
                    controller.ownRunAbandoned()
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

