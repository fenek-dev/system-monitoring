import Foundation
import MonitorModel

/// Raw UI facts the app shell observes (panel open, window occlusion/miniaturize, page, selection).
public struct VisibilityInputs: Equatable, Sendable {
    public var popoverOpen = false
    /// The dashboard window exists and is ordered in.
    public var dashboardOpen = false
    /// `!occlusionState.contains(.visible)` (covered, other Space, screen off).
    public var dashboardOccluded = false
    public var dashboardMiniaturized = false
    public var page: DashboardPage = .overview
    public var selection: NavigationModel.ProcessSelection?

    public init() {}

    /// ARCHITECTURE §7: occluded/miniaturized dashboard ⇒ background; page demand only while visible;
    /// connections only for an app inspected on Processes.
    public var visibility: UIVisibility {
        let visible = dashboardOpen && !dashboardOccluded && !dashboardMiniaturized
        var inspected: AppKey?
        if visible, page == .processes, case .app(let key)? = selection { inspected = key }
        return UIVisibility(popoverOpen: popoverOpen, dashboardVisible: visible, page: visible ? page : nil,
                            inspectedApp: inspected)
    }
}

/// Folds `VisibilityInputs` changes into `UIVisibility` and reports each distinct value once
/// (→ `runtime.setVisibility`, `live.isPresenting`).
@MainActor
public final class VisibilityTracker {
    public private(set) var inputs = VisibilityInputs()
    public private(set) var current: UIVisibility
    private let sink: @MainActor (UIVisibility) -> Void

    public init(sink: @escaping @MainActor (UIVisibility) -> Void) {
        self.sink = sink
        current = inputs.visibility
    }

    public func update(_ mutate: (inout VisibilityInputs) -> Void) {
        mutate(&inputs)
        let v = inputs.visibility
        guard v != current else { return }
        current = v
        sink(v)
    }
}
