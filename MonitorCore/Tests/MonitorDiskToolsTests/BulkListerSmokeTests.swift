import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

/// <base>/root/{plain.bin 1 MiB, small.txt, hl1 + hl2 (hard links), orig.bin + clone.bin (APFS clone),
/// sub/inner.txt, sym → sub}, all with a fixed mtime.
final class BulkTempTree {
    static let fixedMtime: Int64 = 1_700_000_000
    let base: URL
    var root: String { base.appendingPathComponent("root").path }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
        let fm = FileManager.default
        let root = base.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        func random(_ count: Int) -> Data { Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }) }
        try random(1_048_576).write(to: root.appendingPathComponent("plain.bin"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("small.txt"))
        try random(8192).write(to: root.appendingPathComponent("hl1"))
        try fm.linkItem(at: root.appendingPathComponent("hl1"), to: root.appendingPathComponent("hl2"))
        try random(1_048_576).write(to: root.appendingPathComponent("orig.bin"))
        guard clonefile(root.appendingPathComponent("orig.bin").path, root.appendingPathComponent("clone.bin").path, 0) == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try Data("inner".utf8).write(to: root.appendingPathComponent("sub/inner.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("sym").path, withDestinationPath: "sub")
        for path in ["plain.bin", "small.txt", "hl1", "orig.bin", "clone.bin", "sub/inner.txt", "sub", ""] {
            var times = [timeval(tv_sec: Int(Self.fixedMtime), tv_usec: 0), timeval(tv_sec: Int(Self.fixedMtime), tv_usec: 0)]
            let target = path.isEmpty ? root.path : root.appendingPathComponent(path).path
            guard utimes(target, &times) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    deinit { try? FileManager.default.removeItem(at: base) }
}

/// Expected listing values from `lstat` and single-object `getattrlist`: nothing here goes through the bulk parser
/// or the lister under test.
enum BulkReference {
    static func entry(_ directory: String, _ name: String, privateBytes: UInt64? = nil) throws -> BulkFixture.ExpectedEntry {
        let path = directory + "/" + name
        var st = stat()
        guard lstat(path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let kind: String
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = "regular"
        case S_IFDIR: kind = "directory"
        case S_IFLNK: kind = "symlink"
        default: kind = "other"
        }
        let isDirectory = kind == "directory"
        return BulkFixture.ExpectedEntry(
            name: name, kind: kind, fileID: st.st_ino, mtime: Int64(st.st_mtimespec.tv_sec),
            addedTime: try addedTime(path), fileFlags: st.st_flags,
            mountStatus: isDirectory ? try mountStatus(path) : 0,
            // Directories carry no link-count attribute in a bulk entry; the parser's default is 1.
            linkCount: isDirectory ? 1 : UInt32(st.st_nlink),
            allocBytes: isDirectory ? 0 : UInt64(st.st_blocks) * 512, privateBytes: privateBytes, errorCode: 0)
    }

    static func addedTime(_ path: String) throws -> Int64 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var reply = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &list, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    static func mountStatus(_ path: String) throws -> UInt32 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        var reply = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &list, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    }
}

private func listAll(_ lister: some DirectoryLister, _ rel: RelativePath? = nil) throws -> [ListedEntry] {
    let handle = try lister.open(rel)
    var all: [ListedEntry] = []
    while true {
        let batch = try lister.list(handle)
        all += batch.entries
        if batch.done || batch.entries.isEmpty { return all }
    }
}

private func byName(_ entries: [ListedEntry]) -> [String: ListedEntry] {
    Dictionary(uniqueKeysWithValues: entries.map { (String(decoding: $0.name, as: UTF8.self), $0) })
}

/// Real directories, no special hardware: runs in CI.
@Suite struct BulkListerRescanTests {
    /// Bug: the root listing reused a dup of the root descriptor, which shares its directory cursor: a second
    /// listing (or one overlapping the first) saw no entries and the scan looked empty.
    @Test func rootCanBeListedAgainAndConcurrently() throws {
        let tree = try BulkTempTree()
        let lister = BulkLister(rootPath: tree.root)
        _ = try lister.rootInfo()
        defer { lister.release() }
        let first = try listAll(lister)
        let second = try listAll(lister)
        #expect(Set(first.map(\.name)).count == 8)
        #expect(first == second)

        let a = try lister.open(nil)
        let b = try lister.open(nil)
        let fromA = try lister.list(a).entries
        let fromB = try lister.list(b).entries
        #expect(fromA == first && fromB == first)
    }

    /// Bug: the trusted root's descriptor outlives the scan and keeps the volume busy.
    @Test func releasingTheLastUserClosesTheRoot() throws {
        let tree = try BulkTempTree()
        let lister = BulkLister(rootPath: tree.root)
        _ = try lister.rootInfo()
        _ = try lister.rootInfo()
        #expect(lister.rootDescriptor != nil)
        lister.release()
        #expect(lister.rootDescriptor != nil)
        lister.release()
        #expect(lister.rootDescriptor == nil)
        #expect(throws: ListError.self) { try lister.open(nil) }
    }

    /// Bug: describing a single file opens it (materializing a placeholder) or follows a symlink.
    @Test func attributesDescribeASymlinkWithoutFollowingIt() throws {
        let tree = try BulkTempTree()
        let lister = BulkLister(rootPath: tree.root)
        _ = try lister.rootInfo()
        defer { lister.release() }
        let entry = try lister.attributes(of: try RelativePath(validating: "sym"))
        #expect(entry.kind == .symlink)
        #expect(String(decoding: entry.name, as: UTF8.self) == "sym")
    }
}

/// Real-filesystem checks, gated like `VolumeSmokeTests`. `TELLTALE_RECORD_BULK=1` additionally rewrites the
/// fixtures under `Fixtures/bulk` from a deterministic temp tree (never from a real home).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
struct BulkListerSmokeTests {
    private func lister(for tree: BulkTempTree, privateSize: Bool = false) throws -> BulkLister {
        let lister = BulkLister(rootPath: tree.root, includePrivateSize: privateSize)
        _ = try lister.rootInfo()
        return lister
    }

    /// Bug: the bulk lister disagrees with the filesystem about what is in a directory: every field is compared with
    /// values read through `lstat` / single-object `getattrlist` (flags, added time and mount status included).
    @Test func bulkListingMatchesIndependentReads() throws {
        let tree = try BulkTempTree()
        let lister = try lister(for: tree)
        defer { lister.release() }
        let listed = byName(try listAll(lister))
        #expect(Set(listed.keys) == ["plain.bin", "small.txt", "hl1", "hl2", "orig.bin", "clone.bin", "sub", "sym"])
        for (name, actual) in listed {
            let expected = try BulkReference.entry(tree.root, name)
            #expect(BulkFixture.ExpectedEntry(actual) == expected, "\(name)")
        }
        #expect(listed["hl1"]?.linkCount == 2)
        #expect(listed["sym"]?.kind == .symlink)
    }

    /// Bug: a mount point is not recognised, so the walk would enter other volumes.
    @Test func mountStatusMatchesGetattrlistOnSystemVolumes() throws {
        let lister = BulkLister(rootPath: "/System/Volumes")
        _ = try lister.rootInfo()
        defer { lister.release() }
        for entry in try listAll(lister) where entry.kind == .directory {
            let name = String(decoding: entry.name, as: UTF8.self)
            #expect(entry.mountStatus == (try BulkReference.mountStatus("/System/Volumes/" + name)), "\(name)")
        }
    }

    /// Bug: the walker follows a symlink out of the tree.
    @Test func symlinkIsListedButNeverOpened() throws {
        let tree = try BulkTempTree()
        let lister = try lister(for: tree)
        defer { lister.release() }
        #expect(byName(try listAll(lister))["sym"]?.kind == .symlink)
        #expect(throws: ListError.self) { try lister.open(try RelativePath(validating: "sym")) }
    }

    /// Spikes §3: a clone pair shares extents (private 0 each); a plain file is entirely private.
    @Test func privateSizeOfClonesAndPlainFiles() throws {
        let tree = try BulkTempTree()
        let lister = try lister(for: tree, privateSize: true)
        defer { lister.release() }
        let entries = byName(try listAll(lister))
        let plain = try #require(entries["plain.bin"])
        #expect(plain.privateBytes == plain.allocBytes)
        #expect(entries["orig.bin"]?.privateBytes == 0)
        #expect(entries["clone.bin"]?.privateBytes == 0)
    }

    /// Single-file path of the private-size pass: `getattrlistat` returns the same record layout.
    @Test func singleFileAttributesMatchTheListing() throws {
        let tree = try BulkTempTree()
        let lister = try lister(for: tree, privateSize: true)
        defer { lister.release() }
        let listed = try #require(byName(try listAll(lister))["plain.bin"])
        let single = try lister.attributes(of: try RelativePath(validating: "plain.bin"))
        #expect(single == listed)
    }

    /// Rewrites `Fixtures/bulk/*` from real kernel buffers of `BulkTempTree` (entries picked and ordered per
    /// fixture). Expected values come from `BulkReference`, never from the parser the fixtures test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TELLTALE_RECORD_BULK"] == "1"))
    func recordFixtures() throws {
        let tree = try BulkTempTree()
        let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bulk")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        func chunks(includePrivate: Bool) throws -> [String: [UInt8]] {
            let fd = open(tree.root, O_RDONLY | O_DIRECTORY)
            #expect(fd >= 0)
            defer { close(fd) }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 8)
            defer { buffer.deallocate() }
            let count = try BulkAttrParser.fetchRaw(fd: fd, into: buffer, includePrivateSize: includePrivate)
            var result: [String: [UInt8]] = [:]
            var offset = 0
            for _ in 0 ..< count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let bytes = Array(buffer[offset ..< offset + length])
                // Only the name is read back, to file the chunk; expected values come from BulkReference.
                let entry = try bytes.withUnsafeBytes { try BulkAttrParser.parse($0, count: 1)[0] }
                result[String(decoding: entry.name, as: UTF8.self)] = bytes
                offset += length
            }
            return result
        }

        func write(_ name: String, origin: String, _ names: [String], from chunks: [String: [UInt8]],
                   privateBytes: (String) throws -> UInt64?) throws {
            let parts = try names.map { n in try #require(chunks[n]) }
            try Data(parts.flatMap { $0 }).write(to: outDir.appendingPathComponent("\(name).bin"))
            let expected = try names.map { try BulkReference.entry(tree.root, $0, privateBytes: try privateBytes($0)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(BulkFixture.Expectation(origin: origin, entries: expected))
                .write(to: outDir.appendingPathComponent("\(name).json"))
        }

        let plain = try chunks(includePrivate: false)
        let order = "kernel recording, entries reordered"
        try write("dir-then-file", origin: order, ["sub", "small.txt"], from: plain) { _ in nil }
        try write("file-then-dir", origin: order, ["small.txt", "sub"], from: plain) { _ in nil }
        try write("mixed-no-private", origin: "kernel recording, no FSOPT_ATTR_CMN_EXTENDED",
                  ["sub", "sym", "plain.bin", "small.txt", "hl1", "hl2", "orig.bin", "clone.bin"], from: plain) { _ in nil }
        let withPrivate = try chunks(includePrivate: true)
        try write("private-present", origin: "kernel recording, FSOPT_ATTR_CMN_EXTENDED",
                  ["plain.bin", "clone.bin", "orig.bin", "sub"], from: withPrivate) { name in
            // Known by construction: plain.bin is unshared, the clone pair shares every extent, a directory reports 0.
            name == "plain.bin" ? UInt64(try BulkReference.entry(tree.root, name).allocBytes) : 0
        }

        let hand = Self.errorEntry(name: "denied", errorCode: EACCES)
        try Data(hand).write(to: outDir.appendingPathComponent("error-entry.bin"))
        let denied = BulkFixture.ExpectedEntry(name: "denied", kind: "other", fileID: 0, mtime: 0, addedTime: 0,
                                               fileFlags: 0, mountStatus: 0, linkCount: 1, allocBytes: 0,
                                               privateBytes: nil, errorCode: EACCES)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BulkFixture.Expectation(
            origin: "hand-built: the kernel reports ATTR_CMN_ERROR only for entries it cannot stat, which a temp tree "
                + "cannot provoke; layout per man getattrlistbulk (length, returned set, error, name)",
            entries: [denied])).write(to: outDir.appendingPathComponent("error-entry.json"))
    }

    /// `u32 length, attribute_set_t {common = RETURNED|ERROR|NAME}, u32 error, attrreference_t, name + NUL`, padded to 8.
    static func errorEntry(name: String, errorCode: Int32) -> [UInt8] {
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
