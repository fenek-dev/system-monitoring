import Foundation
import MonitorModel
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.10 "SwiftUI environment"). W3 owns this file.

public extension EnvironmentValues {
    @Entry var processActions: ProcessActions = .noop
    @Entry var appCommands: AppCommands = .noop
    @Entry var unitPreferences: UnitPreferences = UnitPreferences()
    @Entry var popoverLayout: PopoverLayout = PopoverLayout()
    @Entry var historyProvider: any HistoryProvider = EmptyHistoryProvider()
    @Entry var isSnapshot: Bool = false
    @Entry var now: Date? = nil
}
