import Foundation

/// Denylist snapshot in tree terms, precomputed by the engine at scan finish / after a clean, so the UI can disable
/// "Move to Trash" (with a reason) without importing `MonitorDiskTools`. Advisory only: the cleaner re-checks
/// every target live.
public struct StoragePolicy: Equatable, Sendable {
    /// Tree this snapshot was computed for; nil only for `.none`.
    public var treeVersion: UInt64?
    /// Nodes a target must not be or contain.
    public var anchors: Set<StorageNodeID>
    /// Nodes a target must not be, contain, or be inside.
    public var protected: Set<StorageNodeID>

    public init(treeVersion: UInt64?, anchors: Set<StorageNodeID>, protected: Set<StorageNodeID>) {
        self.treeVersion = treeVersion
        self.anchors = anchors
        self.protected = protected
    }

    /// No restrictions (mocks, before the first scan).
    public static let none = StoragePolicy(treeVersion: nil, anchors: [], protected: [])

    public func denyReason(trash node: StorageNodeID, in tree: StorageTree) -> DenyReason? {
        if let v = treeVersion, v != tree.version { return .unverifiable }
        for a in anchors where a == node || tree.isAncestor(node, of: a) {
            return .anchor
        }
        for p in protected where p == node || tree.isAncestor(node, of: p) || tree.isAncestor(p, of: node) {
            return .protected
        }
        return nil
    }
}
