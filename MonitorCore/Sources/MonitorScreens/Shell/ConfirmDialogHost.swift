import Foundation
import Observation
import SwiftUI

/// A window-level confirm dialog request (DESIGN §2.26: scrim over the whole window incl. the sidebar, dialog
/// 380 wide with its top at y = 52). Pages ask the shell to present it instead of overlaying their own area.
public struct ConfirmDialogRequest: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var onConfirm: @MainActor @Sendable () -> Void
    public var onCancel: @MainActor @Sendable () -> Void

    public init(id: UUID = UUID(), title: String, message: String, confirmTitle: String,
                onConfirm: @escaping @MainActor @Sendable () -> Void,
                onCancel: @escaping @MainActor @Sendable () -> Void = {}) {
        self.id = id
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }
}

/// `@Environment(\.presentConfirmDialog)`: set by `DashboardRoot` (nil outside a dashboard window, e.g. a page
/// rendered alone; pages then fall back to presenting in their own area).
///
///     @Environment(\.presentConfirmDialog) private var confirm
///     // callback form
///     confirm?(ConfirmDialogRequest(title: "Force Quit “Xcode”?", message: "…", confirmTitle: "Force Quit",
///                                   onConfirm: { … }))
///     // async form: true = confirmed; false = cancelled, replaced, page changed, window closed or task cancelled
///     if await confirm?.confirm(title: "…", message: "…", confirmTitle: "Force Quit") == true { … }
public struct ConfirmDialogPresenter: Sendable {
    private let present: @MainActor @Sendable (ConfirmDialogRequest) -> Void
    private let cancel: @MainActor @Sendable (UUID) -> Void

    public init(present: @escaping @MainActor @Sendable (ConfirmDialogRequest) -> Void,
                cancel: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.present = present
        self.cancel = cancel
    }

    @MainActor public func callAsFunction(_ request: ConfirmDialogRequest) { present(request) }

    /// Cancelling the calling task dismisses the dialog (its `onCancel` path) and returns false.
    @MainActor public func confirm(title: String, message: String, confirmTitle: String) async -> Bool {
        let id = UUID()
        let present = self.present, cancel = self.cancel
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else { return c.resume(returning: false) }
                present(ConfirmDialogRequest(id: id, title: title, message: message, confirmTitle: confirmTitle,
                                             onConfirm: { c.resume(returning: true) },
                                             onCancel: { c.resume(returning: false) }))
            }
        } onCancel: {
            Task { @MainActor in cancel(id) }
        }
    }
}

public extension EnvironmentValues {
    @Entry var presentConfirmDialog: ConfirmDialogPresenter? = nil
}

/// The shell's single dialog slot. Exactly one of `onConfirm`/`onCancel` runs per request: a new request replaces
/// (cancels) the current one; re-presenting the current request is a no-op; `cancel(id:)` (task cancelled),
/// `cancel()` (page change) and `cancelAll()` (window closing) cancel the pending one.
@MainActor @Observable
public final class ConfirmDialogHost {
    public private(set) var current: ConfirmDialogRequest?

    /// Built once (stable identity for the environment). A presenter outliving its host cancels immediately.
    @ObservationIgnored public private(set) lazy var presenter = ConfirmDialogPresenter(
        present: { [weak self] request in
            if let self { self.present(request) } else { request.onCancel() }
        },
        cancel: { [weak self] id in self?.cancel(id: id) })

    public init() {}

    public func present(_ request: ConfirmDialogRequest) {
        guard current?.id != request.id else { return }
        let previous = current
        current = request
        previous?.onCancel()
    }

    public func confirm() {
        guard let r = current else { return }
        current = nil
        r.onConfirm()
    }

    public func cancel() {
        guard let r = current else { return }
        current = nil
        r.onCancel()
    }

    /// Cancels only if `id` is still the one on screen.
    public func cancel(id: UUID) {
        guard current?.id == id else { return }
        cancel()
    }

    public func cancelAll() { cancel() }
}
