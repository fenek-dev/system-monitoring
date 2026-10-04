import MonitorLive
import MonitorModel
import os

/// Asks the user; false = declined (or no dialog available).
typealias ConfirmAsk = @MainActor (_ title: String, _ message: String, _ confirmTitle: String) async -> Bool

/// Text of the clean confirmation (DESIGN §3.17 Confirm). Pure: the caller passes the totals the model computed.
struct CleanConfirmText: Equatable {
    var title: String
    var message: String

    enum Kind: CaseIterable {
        case permanent, trash, downloads

        var label: String {
            switch self {
            case .permanent: "Delete permanently"
            case .trash: "Move to Trash"
            case .downloads: "Remove downloads"
            }
        }

        var detail: String {
            switch self {
            case .permanent: "caches, build data"
            case .trash: "leftovers, large files"
            case .downloads: "iCloud"
            }
        }

        init(_ mode: DeleteMode) {
            switch mode {
            case .remove, .simctl: self = .permanent
            case .trash: self = .trash
            case .evict: self = .downloads
            // Info-only items are never checkable; they cannot be in a batch.
            case .none: self = .permanent
            }
        }
    }

    /// One line of the breakdown. `bytes` is nil when the model could not account for it ("—").
    struct Part: Equatable {
        var kind: Kind
        var bytes: UInt64?
        var provenance: SizeProvenance
    }

    static let maxInUseNames = 5
    static let confirmTitle = "Clean"

    /// - Parameter total: the footer's selection (hard-link credit included), so the title matches what the footer showed.
    /// - Parameter inUse: items the re-check found in use and unticked; listed so the skip is not silent.
    static func make(parts: [Part], total: UInt64, provenance: SizeProvenance, inUse: [CleanupItem]) -> Self {
        var lines: [String] = []
        for part in parts {
            lines.append("\(part.kind.label): \(StorageFormat.bytes(part.bytes, provenance: part.provenance)) (\(part.kind.detail))")
        }
        if !inUse.isEmpty {
            lines.append("")
            lines.append("In use, skipped:")
            lines.append(contentsOf: inUse.prefix(maxInUseNames).map(\.name))
            if inUse.count > maxInUseNames { lines.append("+\(inUse.count - maxInUseNames) more") }
        }
        return Self(title: "Clean \(StorageFormat.bytes(total, provenance: provenance))?",
                    message: lines.joined(separator: "\n"))
    }
}

/// Spec §7.1: recheck in use → confirm → clean. The dialog is injected so tests drive the flow without a window.
@MainActor
enum CleanFlow {
    enum Outcome: Equatable {
        /// Scanning, cleaning or no tree: nothing was asked or started.
        case unavailable
        case nothingSelected
        case declined
        /// The model refused to start (another run began while the dialog was open).
        case notStarted
        case started
    }

    struct Result: Equatable {
        var outcome: Outcome
        /// Checked items found in use by the re-check (now unticked).
        var newlyInUse: Int
    }

    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    /// No presenter (outside a dashboard window) means nobody can confirm, so nothing is deleted.
    static func ask(_ presenter: ConfirmDialogPresenter?) -> ConfirmAsk {
        guard let presenter else { return { _, _, _ in false } }
        return { title, message, confirmTitle in
            await presenter.confirm(title: title, message: message, confirmTitle: confirmTitle)
        }
    }

    static func run(storage: StorageModel, confirm: ConfirmAsk) async -> Result {
        guard storage.canClean else { return Result(outcome: .unavailable, newlyInUse: 0) }
        let inUse = await storage.recheckInUse()
        let cleanup = storage.cleanup
        let items = cleanup.items.filter { cleanup.checked.contains($0.id) }
        guard !items.isEmpty else { return Result(outcome: .nothingSelected, newlyInUse: inUse.count) }
        // Per-kind totals come from the reclaim accounting (hard-link credit, provenance), not from summing rows.
        let parts = CleanConfirmText.Kind.allCases.compactMap { kind -> CleanConfirmText.Part? in
            let members = items.filter { CleanConfirmText.Kind($0.mode) == kind }
            guard !members.isEmpty else { return nil }
            let reclaim = storage.reclaim(of: members)
            return CleanConfirmText.Part(kind: kind, bytes: reclaim?.bytes, provenance: reclaim?.provenance ?? .unavailable)
        }
        let text = CleanConfirmText.make(parts: parts, total: cleanup.selectedBytes,
                                         provenance: cleanup.selectedProvenance, inUse: inUse)
        guard await confirm(text.title, text.message, CleanConfirmText.confirmTitle) else { return Result(outcome: .declined, newlyInUse: inUse.count) }
        guard storage.clean(items) else {
            log.info("clean not started: another run or scan began while the dialog was open")
            return Result(outcome: .notStarted, newlyInUse: inUse.count)
        }
        return Result(outcome: .started, newlyInUse: inUse.count)
    }
}
