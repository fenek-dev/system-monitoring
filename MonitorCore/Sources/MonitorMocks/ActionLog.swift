import Foundation

// W0b stub (ARCHITECTURE §5.11). Wm replaces this file.

/// Lock-protected; @unchecked allowed only in MonitorMocks.
public final class ActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public var entries: [String] { lock.withLock { storage } }

    public func record(_ entry: String) {
        lock.withLock { storage.append(entry) }
    }
}
