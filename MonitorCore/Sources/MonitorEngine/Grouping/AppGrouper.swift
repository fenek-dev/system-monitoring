import MonitorModel

/// Usage that belongs to no live process (AGX clients whose creator exited, NStat bytes of unresolved or exited
/// pids). The frame assembler adds it to `.system` (ARCHITECTURE §5.1 rule 6, NStat notes).
struct UnattributedUsage: Sendable, Equatable {
    var gpuPercent: Double?
    var netRxBps: Double?
    var netTxBps: Double?

    var isEmpty: Bool { gpuPercent == nil && netRxBps == nil && netTxBps == nil }
}

public struct AppGrouper {
    /// Groups rows by `ProcessSample.app`. Sums are nil when no member has a value (never 0 for unknown).
    /// Sorted by `cpuPercent` desc (nil last), then display name.
    public static func group(_ processes: [ProcessSample], identities: [AppKey: AppIdentity]) -> [AppSample] {
        group(processes, identities: identities, unattributed: UnattributedUsage())
    }

    static func group(_ processes: [ProcessSample], identities: [AppKey: AppIdentity],
                      unattributed: UnattributedUsage) -> [AppSample] {
        var order: [AppKey] = []
        var byKey: [AppKey: AppSample] = [:]
        byKey.reserveCapacity(processes.count / 4)
        for p in processes {
            if byKey[p.app] == nil {
                order.append(p.app)
                byKey[p.app] = AppSample(identity: identities[p.app] ?? defaultIdentity(p.app))
            }
            add(p, to: &byKey[p.app]!)
        }
        if !unattributed.isEmpty {
            if byKey[.system] == nil {
                order.append(.system)
                byKey[.system] = AppSample(identity: identities[.system] ?? .system)
            }
            byKey[.system]!.gpuPercent = sum(byKey[.system]!.gpuPercent, unattributed.gpuPercent)
            byKey[.system]!.netRxBps = sum(byKey[.system]!.netRxBps, unattributed.netRxBps)
            byKey[.system]!.netTxBps = sum(byKey[.system]!.netTxBps, unattributed.netTxBps)
        }
        var apps = order.map { key -> AppSample in
            var a = byKey[key]!
            a.metrics = metrics(of: a)
            return a
        }
        apps.sort(by: ranksBefore)
        return apps
    }

    static func defaultIdentity(_ key: AppKey) -> AppIdentity {
        switch key.kind {
        case .system: .system
        case .other: .other
        case .app, .process: AppIdentity(key: key, displayName: key.id)
        }
    }

    static func ranksBefore(_ a: AppSample, _ b: AppSample) -> Bool {
        switch (a.cpuPercent, b.cpuPercent) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.identity.displayName < b.identity.displayName
        }
    }

    private static func add(_ p: ProcessSample, to a: inout AppSample) {
        if !p.id.isSynthetic { a.processIDs.append(p.id) }
        if p.provenance == .restricted { a.hiddenProcessCount += 1 }
        if p.isCurrentUser { a.isCurrentUser = true }
        a.cpuPercent = sum(a.cpuPercent, p.cpuPercent)
        a.gpuPercent = sum(a.gpuPercent, p.gpuPercent)
        a.memory = sum(a.memory, p.memory)
        a.netRxBps = sum(a.netRxBps, p.netRxBps)
        a.netTxBps = sum(a.netTxBps, p.netTxBps)
        a.diskReadBps = sum(a.diskReadBps, p.diskReadBps)
        a.diskWriteBps = sum(a.diskWriteBps, p.diskWriteBps)
        a.energyWatts = sum(a.energyWatts, p.energyWatts)
        if p.energyEstimated, p.energyWatts != nil { a.energyEstimated = true }
        a.threads = sum(a.threads, p.threads)
        a.connectionCount = sum(a.connectionCount, p.connectionCount)
        if p.preventsSleep { a.preventsSleep = true }
        if p.id.isSynthetic {
            var r = a.coalitionResidual ?? AppMetrics()
            for m in [AppMetric.cpu, .gpu, .diskRead, .diskWrite, .energy] {
                if let v = value(p, m) { r[m] = (r[m] ?? 0) + v }
            }
            a.coalitionResidual = r
        }
    }

    /// Typed fields → vector (`AppSample.value(for:)`, fixed on dev 5ec9d23).
    static func metrics(of a: AppSample) -> AppMetrics {
        var m = AppMetrics()
        for metric in AppMetric.allCases { m[metric] = a.value(for: metric) }
        return m
    }

    /// `ProcessSample.value(for:)` is internal to MonitorModel, hence this mirror.
    private static func value(_ p: ProcessSample, _ m: AppMetric) -> Double? {
        switch m {
        case .cpu: p.cpuPercent
        case .gpu: p.gpuPercent
        case .memory: p.memory.map { Double($0) }
        case .netRx: p.netRxBps
        case .netTx: p.netTxBps
        case .diskRead: p.diskReadBps
        case .diskWrite: p.diskWriteBps
        case .energy: p.energyWatts
        }
    }

    @inline(__always)
    static func sum<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? {
        guard let b else { return a }
        guard let a else { return b }
        return a + b
    }
}
