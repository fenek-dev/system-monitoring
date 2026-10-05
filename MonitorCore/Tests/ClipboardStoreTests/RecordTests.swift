import ClipboardCore
import Foundation
import Testing
@testable import ClipboardStore

@Suite struct RecordTests {
    private func open(_ dir: URL, policy: ClipboardPolicy = .default) throws -> ClipboardStore {
        try ClipboardStore(location: .directory(dir), policy: policy, now: T.t0)
    }

    @Test func recopyMovesItemToTopWithOneRow() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir)
            let a = try #require(try await store.record(T.text("a", app: "Notes"), at: T.t0))
            try await store.record(T.text("b"), at: T.t0 + 1)
            try await store.record(T.text("c"), at: T.t0 + 2)
            let again = try #require(try await store.record(T.text("a", app: "Safari"), at: T.t0 + 3))

            let items = try await store.items()
            #expect(items.map(\.text) == ["a", "c", "b"])
            #expect(again.id == a.id)
            #expect(items[0].createdAt == T.t0)
            #expect(items[0].lastUsedAt == T.t0 + 3)
            #expect(items[0].sourceName == "Safari")
        }
    }

    @Test func recopyKeepsPin() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir)
            let a = try #require(try await store.record(T.text("a"), at: T.t0))
            try await store.record(T.text("b"), at: T.t0 + 1)
            try await store.setPinned(a.id, true)
            try await store.record(T.text("a"), at: T.t0 + 2)

            let items = try await store.items()
            #expect(items.map(\.text) == ["a", "b"])
            #expect(items[0].pinned)
        }
    }

    @Test func undecodableImageReturnsNilAndWritesNothing() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir)
            let result = try await store.record(T.image(Data("not an image".utf8)), at: T.t0)

            #expect(result == nil)
            #expect(try await store.items().isEmpty)
            #expect(try T.fileNames(store.imagesDirectory).isEmpty)
        }
    }

    @Test func corruptDatabaseIsMovedAsideAndStoreOpens() async throws {
        try await T.withDirectory { dir in
            let garbage = Data("this is not a sqlite file, just text padding".utf8)
            try garbage.write(to: dir.appendingPathComponent("clipboard.sqlite"))

            let store = try open(dir)
            try await store.record(T.text("fresh"), at: T.t0)

            #expect(try await store.items().map(\.text) == ["fresh"])
            let aside = try T.fileNames(dir).filter { $0.hasPrefix("clipboard.corrupt-") && $0.hasSuffix(".sqlite") }
            #expect(aside.count == 1)
            #expect(try Data(contentsOf: dir.appendingPathComponent(aside[0])) == garbage)
        }
    }
}
