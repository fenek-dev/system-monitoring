import ClipboardCore
import Foundation
import Testing
@testable import ClipboardStore

@Suite struct StorageTests {
    private func open(_ dir: URL, policy: ClipboardPolicy = .default) throws -> ClipboardStore {
        try ClipboardStore(location: .directory(dir), policy: policy, now: T.t0)
    }

    @Test func imageIsStoredAsPngWithThumbnailAtMostThumbnailPixels() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir)
            let item = try #require(try await store.record(T.image(T.png(width: 400, height: 200)), at: T.t0))

            #expect(item.imageWidth == 400)
            #expect(item.imageHeight == 200)
            #expect(item.imageFile == "\(item.hash).png")
            #expect(item.thumbFile == "\(item.hash).thumb.png")
            let png = try #require(try await store.imageData(item.id))
            #expect(T.pixelSize(png)?.width == 400)
            let thumb = try Data(contentsOf: store.imagesDirectory.appendingPathComponent(try #require(item.thumbFile)))
            #expect(T.pixelSize(thumb)?.width == 128)
            #expect(T.pixelSize(thumb)?.height == 64)
        }
    }

    @Test func listRowsCarryOnlyTheTextPrefix() async throws {
        try await T.withDirectory { dir in
            var policy = ClipboardPolicy()
            policy.previewCharacters = 10
            let store = try open(dir, policy: policy)
            let full = String(repeating: "x", count: 25)
            let item = try #require(try await store.record(T.text(full), at: T.t0))

            #expect(item.text == String(repeating: "x", count: 10))
            #expect(item.textLength == 25)
            #expect(try await store.items()[0].text.count == 10)
            #expect(try await store.fullText(item.id) == full)
        }
    }

    @Test func deletingFilesItemsLeavesTheFilesOnDisk() async throws {
        try await T.withDirectory { dir in
            let target = dir.appendingPathComponent("keep-me.txt")
            try Data("x".utf8).write(to: target)
            let store = try open(dir.appendingPathComponent("store"))
            let item = try #require(try await store.record(ClipCapture(content: .files([target.path])), at: T.t0))
            #expect(item.files == [target.path])

            try await store.delete(item.id)

            #expect(try await store.items().isEmpty)
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func clearUnpinnedKeepsPinnedItems() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir)
            let pinned = try #require(try await store.record(T.text("keep"), at: T.t0))
            try await store.record(T.text("drop"), at: T.t0 + 1)
            try await store.setPinned(pinned.id, true)

            try await store.clearUnpinned()

            #expect(try await store.items().map(\.text) == ["keep"])
        }
    }
}
