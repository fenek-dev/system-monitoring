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

    /// Snapshot-only opt-in: `TTAppTile` loads real app icons even when `isSnapshot` (icon-path golden).
    @Entry var ttAppIconsInSnapshots: Bool = false

    /// Set by `TTTable` for each row's cells: nesting depth (0 = top level, 1 = child row).
    @Entry var ttRowDepth: Int = 0
    /// Set by `TTTable`: whether the row has children, is expanded, and a toggle.
    @Entry var ttRowDisclosure: TTRowDisclosure? = nil
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
