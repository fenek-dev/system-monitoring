import CPrivate
import Foundation
import os

/// Full SMC key sweep (0.45–0.57 s, docs/findings/smc.md), run ONCE off the sampler queue on its own
/// connection, cached in `~/Library/Caches/dev.telltale/smc-keys-<hwModel>-<osBuild>.json`.
/// Only temperature candidates are kept: `T…` keys of type `flt `.
final class SMCKeySweep: Sendable {
    struct Entry: Codable, Sendable, Hashable {
        var key: String
        var type: String
        var size: UInt32
    }

    struct CacheFile: Codable, Sendable, Equatable {
        var hwModel: String
        var osBuild: String
        var keyCount: Int
        var keys: [Entry]
    }

    enum Phase: Sendable, Equatable {
        case idle, running
        case done([Entry], fromCache: Bool, durationNs: UInt64)
        case failed(String)
    }

    let cacheURL: URL
    private let hwModel: String
    private let osBuild: String
    private let phase = OSAllocatedUnfairLock<Phase>(initialState: .idle)
    private let queue = DispatchQueue(label: "dev.telltale.smc-sweep", qos: .utility)

    init(hwModel: String, osBuild: String, cacheDirectory: URL? = nil) {
        self.hwModel = hwModel
        self.osBuild = osBuild
        let dir = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.telltale", isDirectory: true)
        cacheURL = dir.appendingPathComponent("smc-keys-\(Self.safe(hwModel))-\(Self.safe(osBuild)).json")
    }

    var current: Phase { phase.withLock { $0 } }

    /// Temperature candidates once available (cache or finished sweep), else nil.
    var keys: [Entry]? {
        if case let .done(keys, _, _) = current { return keys }
        return nil
    }

    /// Starts the cache load / sweep on the utility queue (idempotent; never blocks the caller).
    func start() {
        let shouldStart = phase.withLock { p -> Bool in
            guard p == .idle else { return false }
            p = .running
            return true
        }
        guard shouldStart else { return }
        queue.async { [self] in
            let result = run()
            phase.withLock { $0 = result }
        }
    }

    /// Blocks until the sweep finished (tests / probes only).
    func wait(timeout: Duration = .seconds(5)) -> Phase {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let p = current
            if p != .running && p != .idle { return p }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return current
    }

    private func run() -> Phase {
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
           cache.hwModel == hwModel, cache.osBuild == osBuild, !cache.keys.isEmpty {
            return .done(cache.keys, fromCache: true, durationNs: 0)
        }
        let t0 = w6bUptimeNs()
        let conn = smc_open()
        guard conn != 0 else { return .failed("smc_open failed") }
        defer { smc_close(conn) }
        var type: UInt32 = 0, size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard smc_read(conn, "#KEY", &type, &bytes, &size) == 0,
              let count = SMCDecoder.decode(key: "#KEY", type: SMCDecoder.fourCC(type), bytes: Array(bytes.prefix(Int(size)))),
              count > 0, count < 20_000 else { return .failed("#KEY unreadable") }
        var out: [Entry] = []
        var name = [CChar](repeating: 0, count: 5)
        for i in 0..<UInt32(count) {
            guard smc_key_at(conn, i, &name) == 0, name[0] == CChar(UInt8(ascii: "T")) else { continue }
            let key = String(decoding: name.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard smc_key_info(conn, key, &type, &size) == 0, SMCDecoder.fourCC(type) == "flt ", size == 4 else { continue }
            out.append(Entry(key: key, type: "flt ", size: size))
        }
        let file = CacheFile(hwModel: hwModel, osBuild: osBuild, keyCount: Int(count), keys: out)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file), (try? data.write(to: cacheURL, options: .atomic)) != nil {
            pruneStaleCaches()
        }
        return .done(out, fromCache: false, durationNs: w6bUptimeNs() - t0)
    }

    /// Removes this model's caches for other OS builds (`smc-keys-<model>-<oldBuild>.json`).
    private func pruneStaleCaches() {
        let dir = cacheURL.deletingLastPathComponent()
        let current = cacheURL.lastPathComponent
        let prefix = String(current.prefix(current.count - "\(osBuildComponent).json".count))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name != current && name.hasPrefix(prefix) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private var osBuildComponent: String { Self.safe(osBuild) }

    static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "," || $0 == "." ? $0 : "_" })
    }
}
