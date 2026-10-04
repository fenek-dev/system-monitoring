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

        init(name: String, kind: String, fileID: UInt64, mtime: Int64, addedTime: Int64, fileFlags: UInt32,
             mountStatus: UInt32, linkCount: UInt32, allocBytes: UInt64, privateBytes: UInt64?, errorCode: Int32) {
            self.name = name
            self.kind = kind
            self.fileID = fileID
            self.mtime = mtime
            self.addedTime = addedTime
            self.fileFlags = fileFlags
            self.mountStatus = mountStatus
            self.linkCount = linkCount
            self.allocBytes = allocBytes
            self.privateBytes = privateBytes
            self.errorCode = errorCode
        }

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

    enum NameCorruption: CaseIterable {
        case offsetPointsAtItself, negativeOffset, emptyName, overlongName, lengthPastEntry, missingTerminator,
             slashInName, embeddedNUL
    }

    /// Bug: a corrupt name reference is trusted: a name aliasing the fixed fields, running off the entry, empty,
    /// overlong, or carrying `/` or NUL would become a path component that escapes or confuses the walk.
    @Test(arguments: NameCorruption.allCases)
    func corruptNameReferenceIsRejected(_ corruption: NameCorruption) throws {
        var fixture = try BulkFixture.load("dir-then-file")
        var bytes = fixture.bytes
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func put(_ value: Int32, at: Int) { withUnsafeBytes(of: value.littleEndian) { for (i, b) in $0.enumerated() { bytes[at + i] = b } } }
        // First entry: length, 5-word returned set, optional error word, then the name reference.
        let hasError = UInt32(u32(4)) & UInt32(ATTR_CMN_ERROR) != 0
        let reference = 24 + (hasError ? 4 : 0)
        let start = reference + Int(Int32(bitPattern: UInt32(u32(reference))))
        let length = u32(reference + 4)
        let expected: BulkAttrParser.ParseError
        switch corruption {
        case .offsetPointsAtItself: put(0, at: reference); expected = .badName("starts inside the fixed fields")
        case .negativeOffset: put(-4, at: reference); expected = .badName("starts inside the fixed fields")
        case .emptyName: put(1, at: reference + 4); expected = .badName("length 1")
        case .overlongName: put(300, at: reference + 4); expected = .badName("length 300")
        case .lengthPastEntry: put(200, at: reference + 4); expected = .truncated
        case .missingTerminator: bytes[start + length - 1] = UInt8(ascii: "x"); expected = .badName("not NUL-terminated")
        case .slashInName: bytes[start] = UInt8(ascii: "/"); expected = .badName("NUL or '/' in name")
        case .embeddedNUL: bytes[start] = 0; expected = .badName("NUL or '/' in name")
        }
        fixture.bytes = bytes
        #expect(throws: expected) { try fixture.parse() }
    }

    /// Bug: an attribute group the parser has no layout for is skipped over, and every later field of the entry (and
    /// the next entries) is read from the wrong offset.
    @Test func unsupportedAttributeGroupFailsBeforeAnyLaterField() throws {
        var fixture = try BulkFixture.load("dir-then-file")
        fixture.bytes[8] = 1 // volume attribute word of the first entry's returned set
        #expect(throws: BulkAttrParser.ParseError.unsupported("volume 1")) { try fixture.parse() }
    }

    /// Bug: a short or corrupt buffer is read past its end instead of rejected.
    @Test(arguments: BulkFixture.names)
    func truncatedBufferIsRejected(_ name: String) throws {
        let fixture = try BulkFixture.load(name)
        let cut = Array(fixture.bytes.dropLast())
        #expect(throws: BulkAttrParser.ParseError.truncated) { try fixture.parse(cut) }
    }
}
