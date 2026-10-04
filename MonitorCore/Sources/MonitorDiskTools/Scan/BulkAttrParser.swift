import Darwin
import Foundation

/// Requests and decodes `getattrlistbulk` buffers. All raw-pointer code of the scanner lives here.
///
/// Layout of one entry (`man getattrlistbulk`, fixtures in `Tests/…/Fixtures/bulk`): `u32 length`, the returned
/// `attribute_set_t` (5 × u32), then `ATTR_CMN_ERROR` if returned, then the common attributes in bit order (name
/// reference, object type, mtime, flags, file id, added time), directory attributes, file attributes, fork
/// attributes. `FSOPT_PACK_INVAL_ATTRS` does not fix the layout (a directory has no file attributes), so every entry
/// is decoded by its own returned mask.
enum BulkAttrParser {
    enum ParseError: Error, Equatable {
        /// An entry ran past the buffer or its own length.
        case truncated
        /// The returned mask names an attribute this parser has no layout for.
        case unsupported(String)
        /// The name reference is malformed (see `readName`).
        case badName(String)
    }

    private static let cmnName = attrgroup_t(ATTR_CMN_NAME)
    private static let cmnObjType = attrgroup_t(ATTR_CMN_OBJTYPE)
    private static let cmnModTime = attrgroup_t(ATTR_CMN_MODTIME)
    private static let cmnFlags = attrgroup_t(ATTR_CMN_FLAGS)
    private static let cmnFileID = attrgroup_t(ATTR_CMN_FILEID)
    private static let cmnAddedTime = attrgroup_t(ATTR_CMN_ADDEDTIME)
    private static let cmnError = attrgroup_t(ATTR_CMN_ERROR)
    private static let cmnReturned = ATTR_CMN_RETURNED_ATTRS
    private static let handledCommon = cmnReturned | cmnName | cmnObjType | cmnModTime | cmnFlags | cmnFileID
        | cmnAddedTime | cmnError
    private static let dirMountStatus = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    private static let fileLinkCount = attrgroup_t(ATTR_FILE_LINKCOUNT)
    private static let fileAllocSize = attrgroup_t(ATTR_FILE_ALLOCSIZE)
    private static let forkPrivateSize = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

    private static let objTypeRegular: UInt32 = 1 // VREG
    private static let objTypeDirectory: UInt32 = 2 // VDIR
    private static let objTypeSymlink: UInt32 = 5 // VLNK

    // MARK: - Syscalls

    private static func attrList(includePrivateSize: Bool) -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = handledCommon
        list.dirattr = dirMountStatus
        list.fileattr = fileLinkCount | fileAllocSize
        // The extended fork bit is only honoured together with FSOPT_ATTR_CMN_EXTENDED.
        list.forkattr = includePrivateSize ? forkPrivateSize : 0
        return list
    }

    /// No `FSOPT_PACK_INVAL_ATTRS`: it pads entries with defaults for attributes the filesystem cannot supply, which
    /// hides "not returned" behind plausible zeros. The returned mask alone says what is present.
    private static func options(includePrivateSize: Bool) -> UInt64 {
        includePrivateSize ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0
    }

    /// One raw `getattrlistbulk` call into `buffer`: the number of entries written (0 = directory exhausted). Split
    /// from `fetch` so the fixture recorder can capture the untouched bytes.
    static func fetchRaw(fd: Int32, into buffer: UnsafeMutableRawBufferPointer,
                         includePrivateSize: Bool) throws(ListError) -> Int {
        var list = attrList(includePrivateSize: includePrivateSize)
        var count: Int32
        repeat {
            count = getattrlistbulk(fd, &list, buffer.baseAddress, buffer.count,
                                    options(includePrivateSize: includePrivateSize))
        } while count < 0 && Darwin.errno == EINTR
        guard count >= 0 else { throw ListError(errno: Darwin.errno, op: "getattrlistbulk") }
        return Int(count)
    }

    /// One `getattrlistbulk` call into `buffer`; empty result = the directory is exhausted.
    static func fetch(fd: Int32, into buffer: UnsafeMutableRawBufferPointer,
                      includePrivateSize: Bool) throws(ListError) -> [ListedEntry] {
        let count = try fetchRaw(fd: fd, into: buffer, includePrivateSize: includePrivateSize)
        do {
            return try parse(UnsafeRawBufferPointer(rebasing: buffer[...]), count: count)
        } catch {
            throw ListError(errno: EIO, op: "getattrlistbulk buffer: \(error)")
        }
    }

    /// Attributes of `name` inside `parent` (same record layout as one bulk entry), without opening the object and
    /// without following a final symlink: a dataless file is described, never materialized.
    static func fetchOne(parent: Int32, name: String, includePrivateSize: Bool) throws(ListError) -> ListedEntry {
        var list = attrList(includePrivateSize: includePrivateSize)
        let size = 4096
        let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 8)
        defer { storage.deallocate() }
        let flags = UInt(FSOPT_NOFOLLOW) | UInt(options(includePrivateSize: includePrivateSize))
        guard getattrlistat(parent, name, &list, storage.baseAddress, size, flags) == 0
        else { throw ListError(errno: Darwin.errno, op: "getattrlistat \(name)") }
        do {
            return try parse(UnsafeRawBufferPointer(rebasing: storage[...]), count: 1)[0]
        } catch {
            throw ListError(errno: EIO, op: "getattrlistat buffer: \(error)")
        }
    }

    // MARK: - Decoding

    static func parse(_ buffer: UnsafeRawBufferPointer, count: Int) throws(ParseError) -> [ListedEntry] {
        var entries: [ListedEntry] = []
        entries.reserveCapacity(count)
        var offset = 0
        for _ in 0 ..< count {
            guard offset + 4 <= buffer.count else { throw .truncated }
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= 4, offset + length <= buffer.count else { throw .truncated }
            entries.append(try parseEntry(UnsafeRawBufferPointer(rebasing: buffer[offset ..< offset + length])))
            offset += length
        }
        return entries
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var position = 0

        mutating func read<T>(_: T.Type) throws(ParseError) -> T {
            guard position + MemoryLayout<T>.size <= bytes.count else { throw .truncated }
            defer { position += MemoryLayout<T>.size }
            return bytes.loadUnaligned(fromByteOffset: position, as: T.self)
        }
    }

    private static func parseEntry(_ entry: UnsafeRawBufferPointer) throws(ParseError) -> ListedEntry {
        var r = Reader(bytes: entry)
        _ = try r.read(UInt32.self) // length
        let common = try r.read(UInt32.self)
        let volume = try r.read(UInt32.self)
        let dir = try r.read(UInt32.self)
        let file = try r.read(UInt32.self)
        let fork = try r.read(UInt32.self)
        guard common & ~handledCommon == 0 else { throw .unsupported("common \(common)") }
        guard volume == 0 else { throw .unsupported("volume \(volume)") }
        guard dir & ~dirMountStatus == 0 else { throw .unsupported("dir \(dir)") }
        guard file & ~(fileLinkCount | fileAllocSize) == 0 else { throw .unsupported("file \(file)") }
        guard fork & ~forkPrivateSize == 0 else { throw .unsupported("fork \(fork)") }

        guard common & cmnName != 0 else { throw .badName("no name returned") }
        var result = ListedEntry(name: [], kind: .other)
        if common & cmnError != 0 { result.errorCode = Int32(bitPattern: try r.read(UInt32.self)) }
        let referenceAt = r.position
        let nameOffset = Int(try r.read(Int32.self))
        let nameLength = Int(try r.read(UInt32.self))
        if common & cmnObjType != 0 {
            switch try r.read(UInt32.self) {
            case objTypeRegular: result.kind = .regular
            case objTypeDirectory: result.kind = .directory
            case objTypeSymlink: result.kind = .symlink
            default: result.kind = .other
            }
        }
        if common & cmnModTime != 0 { result.mtime = try readSeconds(&r) }
        if common & cmnFlags != 0 { result.fileFlags = try r.read(UInt32.self) }
        if common & cmnFileID != 0 { result.fileID = try r.read(UInt64.self) }
        if common & cmnAddedTime != 0 { result.addedTime = try readSeconds(&r) }
        if dir & dirMountStatus != 0 { result.mountStatus = try r.read(UInt32.self) }
        if file & fileLinkCount != 0 { result.linkCount = try r.read(UInt32.self) }
        if file & fileAllocSize != 0 { result.allocBytes = UInt64(clamping: try r.read(Int64.self)) }
        if fork & forkPrivateSize != 0 { result.privateBytes = UInt64(clamping: try r.read(Int64.self)) }
        result.name = try readName(in: entry, referenceAt: referenceAt, offset: nameOffset, length: nameLength,
                                   fixedEnd: r.position)
        return result
    }

    /// The name is variable data after the fixed fields: it must start behind them (never overlap an attribute),
    /// end inside the entry with a NUL, and be a plausible single path component. A corrupt buffer is rejected here
    /// rather than becoming a name that escapes the directory (`/`, `..`) or aliases other fields.
    private static func readName(in entry: UnsafeRawBufferPointer, referenceAt: Int, offset: Int, length: Int,
                                 fixedEnd: Int) throws(ParseError) -> [UInt8] {
        let start = referenceAt + offset
        guard offset >= 0, start >= fixedEnd else { throw .badName("starts inside the fixed fields") }
        // `length` counts the terminating NUL: at least one name byte plus the NUL, at most NAME_MAX bytes.
        guard length >= 2, length <= Int(NAME_MAX) + 1 else { throw .badName("length \(length)") }
        guard start + length <= entry.count else { throw .truncated }
        guard entry[start + length - 1] == 0 else { throw .badName("not NUL-terminated") }
        let name = Array(entry[start ..< start + length - 1])
        guard !name.contains(0), !name.contains(UInt8(ascii: "/")) else { throw .badName("NUL or '/' in name") }
        guard name != [UInt8(ascii: ".")], name != [UInt8(ascii: "."), UInt8(ascii: ".")] else {
            throw .badName("dot entry")
        }
        return name
    }

    private static func readSeconds(_ r: inout Reader) throws(ParseError) -> Int64 {
        let seconds = try r.read(Int64.self)
        _ = try r.read(Int64.self) // tv_nsec
        return seconds
    }
}
