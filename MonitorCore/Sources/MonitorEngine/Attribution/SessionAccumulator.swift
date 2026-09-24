import MonitorModel

/// Per `AppKey` since launch: CPU time, GPU time, network rx/tx. Totals outlive the processes and the app itself;
/// if a process moves to another key, its new deltas accrue there and the old key keeps what it had.
public struct SessionAccumulator: Sendable {
    private var totalsByKey: [AppKey: ProcessDelta] = [:]

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

    /// Already-grouped deltas (synthetic coalition rows, unattributed GPU/net → `.system`).
    mutating func add(byApp: [AppKey: ProcessDelta]) {
        for (key, d) in byApp { totalsByKey[key, default: ProcessDelta()].accumulate(d) }
    }

    public func totals(_ key: AppKey) -> (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64) {
        let t = totalsByKey[key] ?? ProcessDelta()
        return (t.cpuNs, t.gpuNs, t.rx, t.tx)
    }

    var keyCount: Int { totalsByKey.count }
}

extension ProcessDelta {
    /// Saturating field-wise add.
    mutating func accumulate(_ d: ProcessDelta) {
        cpuNs = ProcessAssembler.saturatingAdd(cpuNs, d.cpuNs)
        gpuNs = ProcessAssembler.saturatingAdd(gpuNs, d.gpuNs)
        rx = ProcessAssembler.saturatingAdd(rx, d.rx)
        tx = ProcessAssembler.saturatingAdd(tx, d.tx)
    }
}
