import Foundation
import MonitorLive
import MonitorModel

public extension UIVisibility {
    /// What `LiveModel` publishes for this visibility: everything while the popover or dashboard is visible,
    /// only the totals while just the overlay is, nothing otherwise.
    var livePresentation: LivePresentation {
        switch mode {
        case .interactive: .full
        case .overlay: .overlay
        case .background, .paused: .none
        }
    }
}

/// Raw UI facts the app shell observes (panel open, window occlusion/miniaturize, page, inspected app).
public struct VisibilityInputs: Equatable, Sendable {
    public var popoverOpen = false
    /// The dashboard window exists and is ordered in.
    public var dashboardOpen = false
    /// `!occlusionState.contains(.visible)` (covered, other Space, screen off).
    public var dashboardOccluded = false
    public var dashboardMiniaturized = false
    public var page: DashboardPage = .overview
    /// `NavigationModel.inspectedApp` (ICR-10).
    public var inspectedApp: AppKey?
    /// The overlay panel is shown (`OverlayPanelController`).
    public var overlayVisible = false

    public init() {}

    /// ARCHITECTURE §7: occluded/miniaturized dashboard ⇒ background; page demand only while visible;
    /// connections only for an app inspected on Processes.
    public var visibility: UIVisibility {
        let visible = dashboardOpen && !dashboardOccluded && !dashboardMiniaturized
        let inspected = visible && page == .processes ? inspectedApp : nil
        return UIVisibility(popoverOpen: popoverOpen, dashboardVisible: visible, page: visible ? page : nil,
                            inspectedApp: inspected, overlayVisible: overlayVisible)
    }
}

/// Folds `VisibilityInputs` changes into `UIVisibility` and reports each distinct value once
/// (→ `runtime.setVisibility`, `live.presentation`).
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
