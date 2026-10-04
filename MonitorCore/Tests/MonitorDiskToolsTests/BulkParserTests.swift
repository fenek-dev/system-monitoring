import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

/// A recorded `getattrlistbulk` buffer plus the entries it must decode to (see `BulkListerSmokeTests.recordFixtures`).
struct BulkFixture {
    struct ExpectedEntry: Codable, Equatable {
        var name: String
        var kind: String
        var fileID: UInt64
        var mtime: Int64
        var addedTime: Int64
        var fileFlags: UInt32
        var mountStatus: UInt32
        var linkCount: UInt32
        var allocBytes: UInt64
        var privateBytes: UInt64?
        var errorCode: Int32

        init(_ entry: ListedEntry) {
            name = String(decoding: entry.name, as: UTF8.self)
            kind = "\(entry.kind)"
            fileID = entry.fileID
            mtime = entry.mtime
            addedTime = entry.addedTime
            fileFlags = entry.fileFlags
            mountStatus = entry.mountStatus
            linkCount = entry.linkCount
            allocBytes = entry.allocBytes
            privateBytes = entry.privateBytes
            errorCode = entry.errorCode
        }
    }

    struct Expectation: Codable {
        /// What produced the bytes: a real kernel recording, or a hand-built buffer (kernel errors are hard to provoke).
        var origin: String
        var entries: [ExpectedEntry]
    }

    static let names = ["dir-then-file", "file-then-dir", "private-present", "mixed-no-private", "error-entry"]

    var bytes: [UInt8]
    var expectation: Expectation

    static func load(_ name: String) throws -> BulkFixture {
        let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("bulk")
        return BulkFixture(
            bytes: [UInt8](try Data(contentsOf: dir.appendingPathComponent("\(name).bin"))),
            expectation: try JSONDecoder().decode(Expectation.self,
                                                  from: Data(contentsOf: dir.appendingPathComponent("\(name).json")))
        )
    }

    func parse(_ bytes: [UInt8]? = nil) throws -> [ListedEntry] {
        let data = bytes ?? self.bytes
        return try data.withUnsafeBytes { try BulkAttrParser.parse($0, count: expectation.entries.count) }
    }
}

@Suite struct BulkParserTests {
    /// Bug: reading the buffer with a fixed per-entry layout. Directories carry no file attributes, files carry no
    /// directory attributes, error entries carry almost nothing, and PRIVATESIZE exists only when asked for.
    @Test(arguments: BulkFixture.names)
    func decodesRecordedBuffer(_ name: String) throws {
        let fixture = try BulkFixture.load(name)
        #expect(try fixture.parse().map(BulkFixture.ExpectedEntry.init) == fixture.expectation.entries)
    }

    @Test func fixturesCoverTheLayoutVariants() throws {
        let all = try BulkFixture.names.flatMap { try BulkFixture.load($0).parse() }
        #expect(all.contains { $0.kind == .directory })
        #expect(all.contains { $0.kind == .regular && $0.linkCount > 1 })
        #expect(all.contains { $0.privateBytes != nil })
        #expect(all.contains { $0.kind == .regular && $0.privateBytes == nil })
        #expect(all.contains { $0.errorCode != 0 })
    }

    /// Bug: a short or corrupt buffer is read past its end instead of rejected.
    @Test(arguments: BulkFixture.names)
    func truncatedBufferIsRejected(_ name: String) throws {
        let fixture = try BulkFixture.load(name)
        let cut = Array(fixture.bytes.dropLast())
        #expect(throws: BulkAttrParser.ParseError.truncated) { try fixture.parse(cut) }
    }
}
