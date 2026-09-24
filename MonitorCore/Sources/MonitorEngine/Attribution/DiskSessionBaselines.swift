import MonitorModel

/// ICR-14: per-process disk bytes since Telltale started. Baseline per `ProcessID` at first sight: 0 for a process
/// that started at/after the engine's first process sample (all its I/O is this session's), otherwise its counter
/// then (exact to one tick: processes are sampled from launch). A counter going backwards rebases (no wrap).
/// Baselines survive sleep/wake (`FrameAssembler.reset`) and are dropped when the process exits.
struct DiskSessionBaselines: Sendable {
    private struct Baseline: Sendable { var read: UInt64?, write: UInt64? }
    private var baselines: [ProcessID: Baseline] = [:]
    /// Wall-clock µs of the first process sample (the session start); nil until known.
    private(set) var sessionStartUs: UInt64?

    mutating func start(atUs us: UInt64) {
        if sessionStartUs == nil { sessionStartUs = us }
    }

    /// Session bytes for `p`'s counters (nil where the counter is nil).
    mutating func session(_ p: RawProcess) -> (read: UInt64?, write: UInt64?) {
        let newborn = sessionStartUs.map { p.id.startTimeUs >= $0 } ?? false
        var b = baselines[p.id] ?? Baseline(read: p.diskReadBytes.map { newborn ? 0 : $0 },
                                            write: p.diskWriteBytes.map { newborn ? 0 : $0 })
        func since(_ counter: UInt64?, _ base: inout UInt64?) -> UInt64? {
            guard let counter else { return nil }
            guard let b0 = base, counter >= b0 else {
                base = counter                                       // first value, or went backwards → rebase
                return 0
            }
            return counter - b0
        }
        let r = since(p.diskReadBytes, &b.read)
        let w = since(p.diskWriteBytes, &b.write)
        baselines[p.id] = b
        return (r, w)
    }

    mutating func prune(keeping live: Set<ProcessID>) {
        for id in baselines.keys where !live.contains(id) { baselines[id] = nil }
    }

    var count: Int { baselines.count }
}
