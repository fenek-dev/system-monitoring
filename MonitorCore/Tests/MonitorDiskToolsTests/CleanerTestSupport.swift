import Darwin
import Foundation
import MonitorModel
import Synchronization
@testable import MonitorDiskTools

/// A temp world for cleaner tests, entirely below one canonical (`realpath`) directory so `/var` vs `/private/var`
/// never decides a result. Layout: `home/Library/...`, `staging`, `faketrash`, `appdata`.
final class CleanSandbox: Sendable {
    let base: String
    var home: String { base + "/home" }
    var staging: String { base + "/staging" }
    var fakeTrash: String { base + "/faketrash" }
    var appData: String { base + "/appdata" }

    init() throws {
        var template = Array((NSTemporaryDirectory() + "w2c-clean.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template), let resolved = realpath(created, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        base = String(cString: resolved)
        free(resolved)
        for dir in ["home/Library/Caches", "home/Library/Application Support", "faketrash", "appdata"] {
            try FileManager.default.createDirectory(atPath: base + "/" + dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        // Immutable flags and 000/555 directories would make the removal fail silently.
        Self.unlock(base)
        try? FileManager.default.removeItem(atPath: base)
    }

    private static func unlock(_ path: String) {
        guard let walker = FileManager.default.enumerator(atPath: path) else { return }
        for case let rel as String in walker {
            let full = path + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR { chmod(full, 0o700) }
            if st.st_flags & UInt32(UF_IMMUTABLE) != 0 { lchflags(full, st.st_flags & ~UInt32(UF_IMMUTABLE)) }
        }
    }

    func path(_ rel: String) -> String { base + "/" + rel }

    func makeDir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ rel: String, bytes: Int = 4096) throws -> String {
        let full = path(rel)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: full, contents: Data(repeating: 0x61, count: bytes)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return full
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(path(rel), &st) == 0
    }

    func identity(_ rel: String) throws -> FileIdentity {
        var st = stat()
        guard lstat(path(rel), &st) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return FileIdentity(st)
    }

    func list(_ rel: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path(rel))) ?? []).sorted()
    }

    func item(_ id: Int32, _ rel: String, mode: DeleteMode = .remove, keepParent: Bool = false, bytes: UInt64 = 1000,
              node: StorageNodeID? = nil, identity: FileIdentity? = nil) throws -> CleanupItem {
        let scanned = try identity ?? self.identity(rel)
        return CleanupItem(id: id, nodeID: node, path: path(rel), name: (rel as NSString).lastPathComponent,
                           category: .userCaches, tier: .safe, mode: mode, identity: scanned, allocBytes: bytes,
                           keepParent: keepParent)
    }

    func tree(_ entries: [TreeFixture.Entry] = []) -> StorageTree {
        TreeFixture.build(root: .home(home), entries)
    }

    func context(permittedRoot: String? = nil, trash: (any TrashMover)? = nil,
                 deleter: (any Deleter)? = nil, evictor: any Evictor = FakeEvictor(),
                 simctl: any SimctlRunner = FakeSimctl(), inUse: InUseChecker? = nil) -> CleanContext {
        CleanContext(home: home, permittedRoot: permittedRoot ?? home, stagingDir: staging,
                     dataDirectories: [appData], trash: trash ?? FakeTrash(directory: fakeTrash),
                     deleter: deleter ?? DeleteWorker(slim: DeleteWorker.slimSupported(scratchIn: base)),
                     evictor: evictor, simctl: simctl, inUse: inUse)
    }
}

/// What a clean stream delivered, in order.
struct CleanEvents {
    var items: [CleanItemOutcome] = []
    var freed: [UInt64] = []
    var restored: [(itemID: Int32, finalPath: String)] = []
    var finished: [CleanReport] = []
}

func collect(_ stream: AsyncStream<CleanEvent>) async -> CleanEvents {
    var events = CleanEvents()
    for await event in stream {
        switch event {
        case let .item(outcome): events.items.append(outcome)
        case let .freed(bytes): events.freed.append(bytes)
        case let .restored(id, path): events.restored.append((id, path))
        case let .finished(report): events.finished.append(report)
        }
    }
    return events
}

/// Moves the item into `directory` with a plain rename: the same observable result as `trashItem` without touching
/// the real Trash.
final class FakeTrash: TrashMover {
    let directory: String?
    let calls = Mutex(0)

    init(directory: String? = nil) { self.directory = directory }

    func trash(path: String) throws(TrashError) -> String {
        calls.withLock { $0 += 1 }
        guard let directory else { throw .failed("no directory") }
        let destination = directory + "/" + (path as NSString).lastPathComponent
        guard rename(path, destination) == 0 else { throw errno == ENOENT ? .vanished : .failed("errno \(errno)") }
        return destination
    }
}

struct NoTrash: TrashMover {
    func trash(path: String) throws(TrashError) -> String { throw .noTrash }
}

final class FakeEvictor: Evictor {
    let evicted = Mutex<[String]>([])
    func evict(path: String) throws(EvictError) { evicted.withLock { $0.append(path) } }
}

final class FakeSimctl: SimctlRunner {
    let result: SimctlResult
    let runs = Mutex(0)

    init(result: SimctlResult = .success) { self.result = result }

    func deleteUnavailable() -> SimctlResult {
        runs.withLock { $0 += 1 }
        return result
    }
}

/// Real deletion, but each entry waits for a permit from the test first.
final class GatedDeleter: Deleter {
    private let inner: DeleteWorker
    private let gate = DispatchSemaphore(value: 0)

    init(inner: DeleteWorker) { self.inner = inner }

    func release(_ count: Int = 1) { for _ in 0 ..< count { gate.signal() } }

    func delete(_ target: DeleteTarget, clearImmutable: Bool) -> DeleteOutcome {
        gate.wait()
        return inner.delete(target, clearImmutable: clearImmutable)
    }

    func cancelInFlight() { inner.cancelInFlight() }
}
