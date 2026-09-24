import Foundation
import MonitorModel
import SwiftUI

/// App-wide environment (ARCHITECTURE §5.10 "SwiftUI environment") plus UIKit-internal table/menu hooks.
public extension EnvironmentValues {
    @Entry var processActions: ProcessActions = .noop
    @Entry var appCommands: AppCommands = .noop
    @Entry var unitPreferences: UnitPreferences = UnitPreferences()
    @Entry var popoverLayout: PopoverLayout = PopoverLayout()
    @Entry var historyProvider: any HistoryProvider = EmptyHistoryProvider()
    @Entry var isSnapshot: Bool = false
    @Entry var now: Date? = nil

    /// Force Quit always confirms (DESIGN §2.25/§3.12): the page sets this to present `TTConfirmDialog`.
    /// When nil, the menu's "Force Quit…" item is disabled.
    @Entry var requestForceQuit: (@MainActor @Sendable (ProcessTarget) -> Void)? = nil
    /// Called after a Quit from the row menu with the result (the page shows the toast).
    @Entry var onProcessActionResult: (@MainActor @Sendable (ProcessTarget, ActionResult) -> Void)? = nil

    /// Set by `TTTable` for each row's cells: nesting depth (0 = top level, 1 = child row).
    @Entry var ttRowDepth: Int = 0
    /// Set by `TTTable`: whether the row has children, is expanded, and a toggle.
    @Entry var ttRowDisclosure: TTRowDisclosure? = nil
    /// Set by `TTTable` per row: true while the row is hovered or selected (or VoiceOver is on). Inactive rows
    /// skip per-cell tooltips (`MetricValue`) and render `TTRowActionsButton` as a static glyph, so a tick that
    /// changes a row's values does not rebuild tooltips, buttons and menu anchors (W5c pattern). Default true.
    @Entry var ttRowActive: Bool = true
    /// Charts bridge nil runs of up to this many slots between two samples (`ChartSegments.liveBridgeSlots` on the
    /// Live 1-s grid; 0 = strict gap rule, stored ranges). Set by the Live range readers and the popover.
    @Entry var ttChartGapBridge: Int = 0
}

/// Disclosure state handed to a table row's cells (use `TTDisclosureButton` in the name cell).
public struct TTRowDisclosure: Sendable {
    public var hasChildren: Bool
    public var isExpanded: Bool
    public var toggle: @MainActor @Sendable () -> Void

    public init(hasChildren: Bool, isExpanded: Bool, toggle: @escaping @MainActor @Sendable () -> Void) {
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
        self.toggle = toggle
    }
}
