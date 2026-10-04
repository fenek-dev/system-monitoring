import Foundation
import MonitorModel
import Observation

/// Own observable objects so a 10 Hz scan tick, a hover or a checkbox toggle re-renders only the views that read
/// that object.
@MainActor @Observable
public final class ScanProgressState {
    public internal(set) var progress: ScanProgress?

    public init() {}
}

@MainActor @Observable
public final class HoverState {
    public var hoveredID: Int32?

    public init() {}
}
