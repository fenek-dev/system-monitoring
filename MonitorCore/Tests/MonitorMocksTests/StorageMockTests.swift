import Foundation
import Testing
import MonitorModel
@testable import MonitorMocks

@Suite struct StorageMockTests {
    @MainActor
    static func drain(_ stream: AsyncStream<CleanEvent>) async -> [CleanEvent] {
        var events: [CleanEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// Bug: the mock drops or duplicates a logged id, or never emits `.finished`, so W4b confirm-flow tests pass
    /// vacuously or hang.
    @MainActor
    @Test func cleanLogsEachItemOnceAndStreamsInOrder() async throws {
        let state = MockStorageState.make(.map)
        let items = try #require(state.cleanup).items
        let inUse = try #require(items.first { state.inUseIDs.contains($0.id) })
        let trash = try #require(items.first { $0.mode == .trash })
        let remove = try #require(items.first { $0.mode == .remove && $0.id != inUse.id && !$0.keepParent })
        let keep = try #require(items.first { $0.keepParent && $0.id != inUse.id })
        let chosen = [trash, inUse, remove, keep]

        let log = ActionLog()
        let actions = MockDataProvider(scenario: .calm).storageActions(log: log, state: state)
        let events = await Self.drain(actions.clean(chosen))

        #expect(log.storageItemIDs == chosen.map(\.id))
        let outcomes = events.compactMap { event -> CleanItemOutcome? in
            if case let .item(outcome) = event { outcome } else { nil }
        }
        #expect(outcomes.map(\.itemID) == chosen.map(\.id))
        #expect(outcomes[1].skip == .inUse)
        #expect(outcomes[0].trashedTo != nil)
        let tree = try #require(state.tree)
        let first = tree.firstChild[Int(try #require(keep.nodeID))]
        #expect(outcomes[3].removedNodes == Array(first ..< first + tree.childCount[Int(try #require(keep.nodeID))]))
        #expect(events.filter { if case .freed = $0 { true } else { false } }.count <= 1)
        let finishedCount = events.filter { if case .finished = $0 { true } else { false } }.count
        #expect(finishedCount == 1)
        guard case .finished = try #require(events.last) else {
            Issue.record("last event is not .finished")
            return
        }
    }

    /// Bug: nondeterministic fixtures make goldens flaky; a state that never exercises a badge or category leaves
    /// that UI path unrendered.
    @Test(arguments: MockStorageState.Kind.allCases)
    func fixturesAreDeterministicAndCoverBadges(kind: MockStorageState.Kind) throws {
        let a = MockStorageState.make(kind)
        let b = MockStorageState.make(kind)
        #expect(a.tree?.allocBytes == b.tree?.allocBytes)
        #expect(a.tree?.names == b.tree?.names)
        #expect(a.tree?.flags == b.tree?.flags)
        #expect(a.tree?.scanDate == b.tree?.scanDate)
        guard let set = a.cleanup, let tree = a.tree else {
            #expect(kind == .empty || kind == .scanning)
            return
        }
        let other = try #require(b.cleanup)
        #expect(set.items == other.items)
        #expect(set.trashBytes == other.trashBytes)
        #expect(set.treeVersion == tree.version)

        // Bug: summary hand-summed items and skipped hard-link groups that production credits.
        var accumulator = try ReclaimAccumulator(items: set.items, tree: tree, linkSizes: set.linkGroupSizes)
        for item in set.items where !item.ignored && item.mode != .none { accumulator.insert(item.id) }
        #expect(a.summary?.reclaimableBytes == accumulator.bytes)
        #expect(a.summary?.reclaimableBytes != set.items.filter { !$0.ignored && $0.mode != .none }
            .reduce(UInt64(0)) { $0 + ($1.privateBytesExcludingLinks ?? $1.allocBytes) })

        for item in set.items {
            if let node = item.nodeID { #expect(tree.path(node) == item.path) }
        }
        let paths = set.items.map(\.path)
        for p in paths {
            #expect(!paths.contains { $0 != p && p.hasPrefix($0 + "/") }, "\(p) is inside another item")
        }
        #expect(Set(set.items.map(\.category)) == Set(CleanupCategory.allCases))
        #expect(set.items.contains { $0.runningApp })
        #expect(set.items.contains { a.inUseIDs.contains($0.id) })
        #expect(set.items.contains { $0.ignored })
        #expect(set.items.contains { $0.sizeProvenance == .estimate })
        // Docker's data sits in ~/Library/Containers, which `.noFDA` cannot list.
        #expect(set.items.contains { $0.mode == .none } == (kind != .noFDA))
        let owned = Dictionary(grouping: set.items.filter { $0.owner != nil }) {
            "\($0.owner?.bundleID ?? "")/\($0.category.rawValue)"
        }
        #expect(owned.values.contains { $0.count >= 2 })
    }
}
