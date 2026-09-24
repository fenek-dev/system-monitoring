import Foundation
import Observation
import SwiftUI

/// A window-level confirm dialog request (DESIGN §2.26: scrim over the whole window incl. the sidebar, dialog
/// 380 wide with its top at y = 52). Pages ask the shell to present it instead of overlaying their own area.
public struct ConfirmDialogRequest: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var onConfirm: @MainActor @Sendable () -> Void
    public var onCancel: @MainActor @Sendable () -> Void

    public init(title: String, message: String, confirmTitle: String,
                onConfirm: @escaping @MainActor @Sendable () -> Void,
                onCancel: @escaping @MainActor @Sendable () -> Void = {}) {
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
///     // async form: true = confirmed, false = cancelled / replaced / window closed
///     if await confirm?.confirm(title: "…", message: "…", confirmTitle: "Force Quit") == true { … }
public struct ConfirmDialogPresenter: Sendable {
    private let present: @MainActor @Sendable (ConfirmDialogRequest) -> Void

    public init(_ present: @escaping @MainActor @Sendable (ConfirmDialogRequest) -> Void) {
        self.present = present
    }

    @MainActor public func callAsFunction(_ request: ConfirmDialogRequest) { present(request) }

    @MainActor public func confirm(title: String, message: String, confirmTitle: String) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            present(ConfirmDialogRequest(title: title, message: message, confirmTitle: confirmTitle,
                                         onConfirm: { c.resume(returning: true) },
                                         onCancel: { c.resume(returning: false) }))
        }
    }
}

public extension EnvironmentValues {
    @Entry var presentConfirmDialog: ConfirmDialogPresenter? = nil
}

/// The shell's single dialog slot. Exactly one of `onConfirm`/`onCancel` runs per request: a new request replaces
/// (cancels) the current one, and `cancelAll()` (window closing) cancels a pending one.
@MainActor @Observable
public final class ConfirmDialogHost {
    public private(set) var current: ConfirmDialogRequest?

    public init() {}

    public var presenter: ConfirmDialogPresenter {
        ConfirmDialogPresenter { [weak self] request in
            if let self { self.present(request) } else { request.onCancel() }   // window gone: cancel, never hang
        }
    }

    public func present(_ request: ConfirmDialogRequest) {
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

    public func cancelAll() { cancel() }
}
