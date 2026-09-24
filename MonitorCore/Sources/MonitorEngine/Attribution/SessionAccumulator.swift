import MonitorModel

/// Per `AppKey` since launch: CPU time, GPU time, network rx/tx, disk read/write (ICR-14). Totals outlive the processes and the app itself;
/// if a process moves to another key, its new deltas accrue there and the old key keeps what it had.
/// Keys unseen (no row, no delta) for `retentionNs` of uptime are dropped, so one-off executables (`go test` binaries,
/// installer helpers) don't grow the map forever; an app that comes back after that starts from 0. Totals are only
/// read for apps that currently have rows, so nothing sums the dropped keys.
public struct SessionAccumulator: Sendable {
    private struct Entry: Sendable {
        var totals = ProcessDelta()
        var lastSeenNs: UInt64 = 0
    }

    /// 24 h of uptime.
    static let retentionNs: UInt64 = 24 * 3_600 * 1_000_000_000
    /// Unseen keys are looked for at most once per hour.
    static let pruneEveryNs: UInt64 = 3_600 * 1_000_000_000

    private var entries: [AppKey: Entry] = [:]
    private var nextPruneNs: UInt64?

    public init() {}

    /// Deltas are attributed through each app's `processIDs`; deltas of pids in no app are ignored.
    public mutating func add(_ apps: [AppSample], processDeltas: [ProcessID: (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64)]) {
        guard !processDeltas.isEmpty else { return }
        var byApp: [AppKey: ProcessDelta] = [:]
        for app in apps {
            for id in app.processIDs {
                guard let d = processDeltas[id] else { continue }
                byApp[app.identity.key, default: ProcessDelta()].accumulate(ProcessDelta(cpuNs: d.cpuNs, gpuNs: d.gpuNs, rx: d.rx, tx: d.tx))
            }
        }
        add(byApp: byApp)
    }

    /// Already-grouped deltas (synthetic coalition rows, unattributed GPU/net → `.system`); marks those keys seen.
    mutating func add(byApp: [AppKey: ProcessDelta], atUptimeNs now: UInt64 = 0) {
        for (key, d) in byApp {
            var e = entries[key] ?? Entry()
            e.totals.accumulate(d)
            e.lastSeenNs = max(e.lastSeenNs, now)
            entries[key] = e
        }
    }

    /// Totals for an app that has a row this tick; marks the key seen (no entry is created for it).
    mutating func totalsMarkingSeen(_ key: AppKey, atUptimeNs now: UInt64)
        -> (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64, disk: (read: UInt64, write: UInt64)?) {
        guard let e = entries[key] else { return (0, 0, 0, 0, nil) }
        if e.lastSeenNs < now { entries[key]!.lastSeenNs = now }
        let t = e.totals
        return (t.cpuNs, t.gpuNs, t.rx, t.tx, t.hasDisk ? (t.diskR, t.diskW) : nil)
    }

    /// Drops keys unseen for more than `retentionNs`; a no-op until the next hourly check is due.
    mutating func pruneUnseen(atUptimeNs now: UInt64) {
        guard let due = nextPruneNs else {
            nextPruneNs = ProcessAssembler.saturatingAdd(now, Self.pruneEveryNs)
            return
        }
        guard now >= due else { return }
        nextPruneNs = ProcessAssembler.saturatingAdd(now, Self.pruneEveryNs)
        guard now > Self.retentionNs else { return }
        let cutoff = now - Self.retentionNs
        entries = entries.filter { $0.value.lastSeenNs >= cutoff }
    }

    public func totals(_ key: AppKey) -> (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64) {
        let t = entries[key]?.totals ?? ProcessDelta()
        return (t.cpuNs, t.gpuNs, t.rx, t.tx)
    }

    /// ICR-14: disk bytes since Telltale started, per app (never drops when a member exits); nil when no member ever
    /// reported a disk counter.
    public func diskTotals(_ key: AppKey) -> (read: UInt64, write: UInt64)? {
        guard let t = entries[key]?.totals, t.hasDisk else { return nil }
        return (t.diskR, t.diskW)
    }

    var keyCount: Int { entries.count }
}

extension ProcessDelta {
    /// Saturating field-wise add.
    mutating func accumulate(_ d: ProcessDelta) {
        cpuNs = ProcessAssembler.saturatingAdd(cpuNs, d.cpuNs)
        gpuNs = ProcessAssembler.saturatingAdd(gpuNs, d.gpuNs)
        rx = ProcessAssembler.saturatingAdd(rx, d.rx)
        tx = ProcessAssembler.saturatingAdd(tx, d.tx)
        diskR = ProcessAssembler.saturatingAdd(diskR, d.diskR)
        diskW = ProcessAssembler.saturatingAdd(diskW, d.diskW)
        if d.hasDisk { hasDisk = true }
    }
}
