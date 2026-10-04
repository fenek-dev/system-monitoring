import Foundation
import MonitorModel

/// Records every `ProcessActions` invocation the mock UI makes (Processes/Disk pages: Quit, Force Quit,
/// Reveal in Finder, Open in Activity Monitor, Eject), so tests and the demo toast can inspect what
/// happened. Lock-protected; `@unchecked Sendable` is allowed only in `MonitorMocks` (ARCHITECTURE §4).
public final class ActionLog: @unchecked Sendable {
    public enum Kind: String, Sendable {
        case quit, forceQuit, revealInFinder, openInActivityMonitor, eject
        // Storage page (`MockDataProvider.storageActions`).
        case scan, clean, cancelClean, undo, emptyTrash, trash, ignore, unignore
    }

    public struct Entry: Sendable, Equatable {
        public var kind: Kind
        public var targetName: String
        public var result: ActionResult
        public var at: Date

        public init(kind: Kind, targetName: String, result: ActionResult, at: Date = Date()) {
            self.kind = kind
            self.targetName = targetName
            self.result = result
            self.at = at
        }
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    public init() {}

    public var records: [Entry] { lock.withLock { storage } }
    /// `"<kind> <targetName> -> <result>"`, oldest first — handy for quick assertions or a debug print.
    public var entries: [String] { records.map { "\($0.kind.rawValue) \($0.targetName) -> \($0.result)" } }

    /// Item ids from `.clean` / `.trash` entries (storage `clean` logs one per item, target = id), in call order.
    public var storageItemIDs: [Int32] {
        records.filter { $0.kind == .clean || $0.kind == .trash }.compactMap { Int32($0.targetName) }
    }

    @discardableResult
    public func record(_ kind: Kind, target: String, result: ActionResult) -> Entry {
        let entry = Entry(kind: kind, targetName: target, result: result)
        lock.withLock { storage.append(entry) }
        return entry
    }

    public func clear() { lock.withLock { storage.removeAll() } }
}
