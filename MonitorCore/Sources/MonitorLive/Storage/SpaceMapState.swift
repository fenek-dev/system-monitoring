import Foundation
import MonitorModel
import Observation
import os

public enum SpaceMapChildID: Hashable, Sendable {
    case node(StorageNodeID)
    /// Undone item with no tree node to come back to.
    case restored(itemID: Int32)
}

public struct SpaceMapChild: Equatable, Identifiable, Sendable {
    public var id: SpaceMapChildID
    /// Stable id for the tile layout. Nodes keep their id; restored entries map into the negative range, clear of
    /// node ids (>= 0) and of `Int32.min`, which `TTSpaceMap` uses for its "smaller items" tile.
    public var tileID: Int32
    public var name: String
    /// nil = restricted (size unknown).
    public var bytes: UInt64?
    public var isDirectory: Bool

    public init(id: SpaceMapChildID, tileID: Int32, name: String, bytes: UInt64?, isDirectory: Bool) {
        self.id = id
        self.tileID = tileID
        self.name = name
        self.bytes = bytes
        self.isDirectory = isDirectory
    }

    /// Item ids of the classifier are >= 0; "Move to Trash" items use negative ids, mapped to the far end of the
    /// negative range so the two never share a tile id.
    static func tileID(restored itemID: Int32) -> Int32 {
        itemID >= 0 ? -2 - itemID : Int32.min + 1 - itemID
    }
}

@MainActor @Observable
public final class SpaceMapState {
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    public private(set) var tree: StorageTree?
    /// nil while a partial tree is shown: building one per 3 Hz snapshot costs O(nodes), sizes come from the tree.
    public private(set) var overlay: StorageTreeOverlay?
    public private(set) var focus: StorageNodeID = 0

    private struct CacheKey: Equatable {
        var tree: UInt64
        var overlay: UInt64?
    }

    @ObservationIgnored private var cacheKey: CacheKey?
    @ObservationIgnored private var cache: [StorageNodeID: [SpaceMapChild]] = [:]

    public init() {}

    /// Root first, focus last.
    public var breadcrumb: [StorageNodeID] {
        guard let tree else { return [] }
        var chain: [StorageNodeID] = []
        var n = focus
        while true {
            chain.append(n)
            if n == 0 { break }
            n = tree.parent[Int(n)]
        }
        return chain.reversed()
    }

    public func drill(_ node: StorageNodeID) {
        guard let tree, node >= 0, Int(node) < tree.nodeCount, isVisible(node) else { return }
        focus = node
    }

    public func up() {
        guard let tree, focus != 0 else { return }
        focus = tree.parent[Int(focus)]
    }

    public func isVisible(_ node: StorageNodeID) -> Bool {
        guard let tree else { return false }
        guard let overlay else { return true }
        do {
            return try !overlay.isRemoved(node, in: tree)
        } catch {
            Self.log.fault("overlay does not match tree: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Visible children of `node`, largest first (ties by name): `TTSpaceMap` wants presorted tiles and overlay
    /// sizes can reorder the tree's own `childOrder`. Cached per (tree, overlay) version.
    public func children(of node: StorageNodeID) -> [SpaceMapChild] {
        guard let tree, node >= 0, Int(node) < tree.nodeCount else { return [] }
        let key = CacheKey(tree: tree.version, overlay: overlay?.version)
        if cacheKey != key {
            cacheKey = key
            cache.removeAll(keepingCapacity: true)
        }
        if let hit = cache[node] { return hit }
        var result: [SpaceMapChild] = []
        do {
            for child in tree.sortedChildren(node) {
                if let overlay, try overlay.isRemoved(child, in: tree) { continue }
                let flags = tree.flags[Int(child)]
                let bytes = try overlay?.size(child, in: tree) ?? tree.size(child)
                let name = try overlay?.name(child, in: tree) ?? tree.name(child)
                result.append(SpaceMapChild(id: .node(child), tileID: child, name: name, bytes: bytes,
                                            isDirectory: flags.contains(.directory)))
            }
            for entry in overlay?.restoredEntries(under: node) ?? [] {
                result.append(SpaceMapChild(id: .restored(itemID: entry.itemID),
                                            tileID: SpaceMapChild.tileID(restored: entry.itemID),
                                            name: entry.name, bytes: entry.bytes, isDirectory: false))
            }
        } catch {
            Self.log.fault("overlay does not match tree: \(String(describing: error), privacy: .public)")
            return []
        }
        result.sort {
            let (a, b) = ($0.bytes ?? 0, $1.bytes ?? 0)
            if a != b { return a > b }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.tileID < $1.tileID
        }
        cache[node] = result
        return result
    }

    // MARK: - Model-side updates

    /// Unfinished scan: shown only while there is no finished tree. Node ids are stable across snapshots, so a
    /// drilled focus survives.
    func showPartial(_ tree: StorageTree) {
        self.tree = tree
        overlay = nil
        if Int(focus) >= tree.nodeCount { focus = 0 }
    }

    func set(tree: StorageTree, overlay: StorageTreeOverlay) {
        self.tree = tree
        self.overlay = overlay
        focus = 0
    }

    /// A clean/undo changed the overlay: a focus that is now hidden moves to its nearest visible ancestor.
    func setOverlay(_ overlay: StorageTreeOverlay) {
        self.overlay = overlay
        guard let tree else { return }
        while focus != 0, !isVisible(focus) { focus = tree.parent[Int(focus)] }
    }

    func clear() {
        tree = nil
        overlay = nil
        focus = 0
        cacheKey = nil
        cache.removeAll()
    }
}
