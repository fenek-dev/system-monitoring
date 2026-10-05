import ClipboardCore
import CoreGraphics
import Foundation
import Testing
@testable import ClipboardStore

@Suite struct PruneTests {
    private func policy(items: Int = 500, age: TimeInterval = 30 * T.day, imageCap: Int64 = .max) -> ClipboardPolicy {
        var policy = ClipboardPolicy()
        policy.maxItems = items
        policy.maxAge = age
        policy.maxTotalImageBytes = imageCap
        return policy
    }

    private func open(_ dir: URL, _ policy: ClipboardPolicy, now: Date = T.t0) throws -> ClipboardStore {
        try ClipboardStore(location: .directory(dir), policy: policy, now: now)
    }

    @Test func itemCountCapDropsOldestUnpinnedAndKeepsPinned() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir, policy(items: 3))
            let first = try #require(try await store.record(T.text("0"), at: T.t0))
            try await store.setPinned(first.id, true)
            for i in 1...4 { try await store.record(T.text("\(i)"), at: T.t0 + Double(i)) }

            #expect(try await store.items().map(\.text) == ["0", "4", "3", "2"])
        }
    }

    @Test func ageCapDropsOldUnpinnedAndKeepsPinned() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir, policy(age: 10 * T.day))
            try await store.record(T.text("stale"), at: T.t0)
            let kept = try #require(try await store.record(T.text("stale pinned"), at: T.t0))
            try await store.setPinned(kept.id, true)
            try await store.record(T.text("boundary"), at: T.t0 + 1 * T.day)
            try await store.record(T.text("new"), at: T.t0 + 11 * T.day)

            #expect(try await store.items().map(\.text) == ["stale pinned", "new", "boundary"])
        }
    }

    @Test func removedRowsTakeTheirImageFilesWithThem() async throws {
        try await T.withDirectory { dir in
            let store = try open(dir, policy(items: 1))
            let old = try #require(try await store.record(T.image(T.png(red: 0.1)), at: T.t0))
            let new = try #require(try await store.record(T.image(T.png(red: 0.9)), at: T.t0 + 1))

            #expect(try await store.items().map(\.id) == [new.id])
            #expect(try T.fileNames(store.imagesDirectory) == [new.imageFile, new.thumbFile].compactMap { $0 }.sorted())
            #expect(old.imageFile != new.imageFile)
        }
    }

    @Test func openRemovesImageFilesWithoutARow() async throws {
        try await T.withDirectory { dir in
            let kept: ClipItem
            do {
                let store = try open(dir, policy())
                kept = try #require(try await store.record(T.image(T.png()), at: T.t0))
            }
            let images = dir.appendingPathComponent("images")
            try Data([1]).write(to: images.appendingPathComponent("orphan.png"))
            try Data([1]).write(to: images.appendingPathComponent("orphan.thumb.png"))

            let reopened = try open(dir, policy())

            #expect(try T.fileNames(images) == [kept.imageFile, kept.thumbFile].compactMap { $0 }.sorted())
            #expect(try await reopened.items().map(\.id) == [kept.id])
        }
    }

    @Test(arguments: [(false, [1, 2]), (true, [0, 2])])
    func imageByteCapDropsOldestUnpinnedFirst(pinOldest: Bool, survivors: [Int]) async throws {
        try await T.withDirectory { dir in
            let images = (0..<3).map { T.png(red: CGFloat($0) * 0.3) }
            let total: Int64
            do {
                let probe = try open(dir.appendingPathComponent("probe"), policy())
                var sum: Int64 = 0
                for (i, data) in images.enumerated() {
                    sum += try #require(try await probe.record(T.image(data), at: T.t0 + Double(i))).byteSize
                }
                total = sum
            }

            let store = try open(dir.appendingPathComponent("capped"), policy(imageCap: total - 1))
            var recorded: [ClipItem] = []
            for (i, data) in images.enumerated() {
                let item = try #require(try await store.record(T.image(data), at: T.t0 + Double(i)))
                if i == 0, pinOldest { try await store.setPinned(item.id, true) }
                recorded.append(item)
            }

            let remaining = Set(try await store.items().map(\.hash))
            #expect(remaining == Set(survivors.map { recorded[$0].hash }))
        }
    }
}
