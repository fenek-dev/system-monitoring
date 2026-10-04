import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

/// Real-filesystem checks, gated like `VolumeSmokeTests`. `TELLTALE_RECORD_BULK=1` additionally rewrites the
/// fixtures under `Fixtures/bulk` from a deterministic temp tree (never from a real home).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
struct BulkListerSmokeTests {
    static let fixedMtime: Int64 = 1_700_000_000

    /// <base>/root/{plain.bin 1 MiB, small.txt, hl1 + hl2 (hard links), orig.bin + clone.bin (APFS clone),
    /// sub/inner.txt, sym → sub}.
    final class TempTree {
        let base: URL
        var root: String { base.appendingPathComponent("root").path }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
            let fm = FileManager.default
            let root = base.appendingPathComponent("root")
            try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            var generator = SystemRandomNumberGenerator()
            let random = Data((0 ..< 1_048_576).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
            try random.write(to: root.appendingPathComponent("plain.bin"))
            try Data("hello".utf8).write(to: root.appendingPathComponent("small.txt"))
            try Data((0 ..< 8192).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
                .write(to: root.appendingPathComponent("hl1"))
            try fm.linkItem(at: root.appendingPathComponent("hl1"), to: root.appendingPathComponent("hl2"))
            try Data((0 ..< 1_048_576).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
                .write(to: root.appendingPathComponent("orig.bin"))
            guard clonefile(root.appendingPathComponent("orig.bin").path, root.appendingPathComponent("clone.bin").path, 0) == 0
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try Data("inner".utf8).write(to: root.appendingPathComponent("sub/inner.txt"))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("sym").path, withDestinationPath: "sub")
            for path in ["plain.bin", "small.txt", "hl1", "orig.bin", "clone.bin", "sub/inner.txt", "sub", ""] {
                var times = [timeval(tv_sec: Int(BulkListerSmokeTests.fixedMtime), tv_usec: 0),
                             timeval(tv_sec: Int(BulkListerSmokeTests.fixedMtime), tv_usec: 0)]
                let target = path.isEmpty ? root.path : root.appendingPathComponent(path).path
                guard utimes(target, &times) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    private static func listAll(_ lister: some DirectoryLister, _ rel: RelativePath? = nil) throws -> [ListedEntry] {
        let handle = try lister.open(rel)
        var all: [ListedEntry] = []
        while true {
            let batch = try lister.list(handle)
            all += batch.entries
            if batch.done || batch.entries.isEmpty { return all }
        }
    }

    private static func byName(_ entries: [ListedEntry]) -> [String: ListedEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { (String(decoding: $0.name, as: UTF8.self), $0) })
    }

    /// Bug: the bulk lister disagrees with the reference about what is in a directory.
    @Test func bulkListingMatchesFileManagerOnTempTree() throws {
        let tree = try TempTree()
        let bulk = Self.byName(try Self.listAll(BulkLister(root: try TrustedRoot(path: tree.root))))
        let reference = Self.byName(try Self.listAll(FileManagerLister(rootPath: tree.root)))
        #expect(Set(bulk.keys) == Set(reference.keys))
        for (name, expected) in reference {
            let actual = try #require(bulk[name])
            #expect(actual.kind == expected.kind, "\(name) kind")
            #expect(actual.fileID == expected.fileID, "\(name) fileID")
            #expect(actual.mtime == expected.mtime, "\(name) mtime")
            #expect(actual.linkCount == expected.linkCount || expected.kind == .directory, "\(name) linkCount")
            if expected.kind == .regular { #expect(actual.allocBytes == expected.allocBytes, "\(name) allocBytes") }
        }
    }

    /// Bug: the walker follows a symlink out of the tree.
    @Test func symlinkIsListedButNeverOpened() throws {
        let tree = try TempTree()
        let lister = BulkLister(root: try TrustedRoot(path: tree.root))
        let entries = Self.byName(try Self.listAll(lister))
        #expect(entries["sym"]?.kind == .symlink)
        #expect(throws: ListError.self) { try lister.open(try RelativePath(validating: "sym")) }
    }

    /// Spikes §3: a clone pair shares extents (private 0 each); a plain file is entirely private.
    @Test func privateSizeOfClonesAndPlainFiles() throws {
        let tree = try TempTree()
        let lister = BulkLister(root: try TrustedRoot(path: tree.root), includePrivateSize: true)
        let entries = Self.byName(try Self.listAll(lister))
        let plain = try #require(entries["plain.bin"])
        #expect(plain.privateBytes == plain.allocBytes)
        #expect(entries["orig.bin"]?.privateBytes == 0)
        #expect(entries["clone.bin"]?.privateBytes == 0)
    }

    /// Single-file path of the private-size pass: `fgetattrlist` returns the same record layout.
    @Test func singleFileAttributesMatchTheListing() throws {
        let tree = try TempTree()
        let lister = BulkLister(root: try TrustedRoot(path: tree.root), includePrivateSize: true)
        let listed = try #require(Self.byName(try Self.listAll(lister))["plain.bin"])
        let single = try lister.attributes(of: try RelativePath(validating: "plain.bin"))
        #expect(single == listed)
    }

    /// Rewrites `Fixtures/bulk/*` from real kernel buffers of `TempTree` (entries picked and ordered per fixture).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TELLTALE_RECORD_BULK"] == "1"))
    func recordFixtures() throws {
        let tree = try TempTree()
        let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bulk")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        func chunks(includePrivate: Bool) throws -> [(name: String, bytes: [UInt8])] {
            let fd = open(tree.root, O_RDONLY | O_DIRECTORY)
            #expect(fd >= 0)
            defer { close(fd) }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 8)
            defer { buffer.deallocate() }
            let count = try BulkAttrParser.fetchRaw(fd: fd, into: buffer, includePrivateSize: includePrivate)
            var result: [(String, [UInt8])] = []
            var offset = 0
            for _ in 0 ..< count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let bytes = Array(buffer[offset ..< offset + length])
                let entry = try bytes.withUnsafeBytes { try BulkAttrParser.parse($0, count: 1)[0] }
                result.append((String(decoding: entry.name, as: UTF8.self), bytes))
                offset += length
            }
            return result
        }

        func write(_ name: String, origin: String, _ parts: [[UInt8]]) throws {
            let bytes = parts.flatMap { $0 }
            let entries = try bytes.withUnsafeBytes { try BulkAttrParser.parse($0, count: parts.count) }
            try Data(bytes).write(to: outDir.appendingPathComponent("\(name).bin"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(BulkFixture.Expectation(origin: origin, entries: entries.map(BulkFixture.ExpectedEntry.init)))
                .write(to: outDir.appendingPathComponent("\(name).json"))
        }

        let plain = try chunks(includePrivate: false)
        func pick(_ list: [(name: String, bytes: [UInt8])], _ names: [String]) throws -> [[UInt8]] {
            try names.map { name in try #require(list.first { $0.name == name }).bytes }
        }
        try write("dir-then-file", origin: "kernel recording, entries reordered", try pick(plain, ["sub", "small.txt"]))
        try write("file-then-dir", origin: "kernel recording, entries reordered", try pick(plain, ["small.txt", "sub"]))
        try write("mixed-no-private", origin: "kernel recording, kernel order, no FSOPT_ATTR_CMN_EXTENDED",
                  plain.map(\.bytes))
        let withPrivate = try chunks(includePrivate: true)
        try write("private-present", origin: "kernel recording, FSOPT_ATTR_CMN_EXTENDED",
                  try pick(withPrivate, ["plain.bin", "clone.bin", "orig.bin", "sub"]))
        try write("error-entry", origin: "hand-built: the kernel reports ATTR_CMN_ERROR only for entries it cannot stat, "
                  + "which a temp tree cannot provoke; layout per man getattrlistbulk (length, returned set, error, name)",
                  [Self.errorEntry(name: "denied", errorCode: EACCES)])
    }

    /// `u32 length, attribute_set_t {common = RETURNED|ERROR|NAME}, u32 error, attrreference_t, name + NUL`, padded to 8.
    private static func errorEntry(name: String, errorCode: Int32) -> [UInt8] {
        func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        let nameBytes = Array(name.utf8) + [0]
        let headerSize = 4 + 20 + 4 + 8
        let padded = (headerSize + nameBytes.count + 7) / 8 * 8
        var out = le(UInt32(padded))
        out += le(ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME)) + le(0) + le(0) + le(0) + le(0)
        out += le(UInt32(errorCode))
        out += le(8) + le(UInt32(nameBytes.count)) // name sits right after this reference
        out += nameBytes
        out += [UInt8](repeating: 0, count: padded - out.count)
        return out
    }
}
