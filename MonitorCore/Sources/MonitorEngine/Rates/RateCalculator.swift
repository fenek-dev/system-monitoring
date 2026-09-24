/// Counter deltas → per-second rates, timed by the reading's `capturedNs` (ARCHITECTURE §3, §5.6).
///
/// - First sight of a key → nil (baseline stored).
/// - Same `capturedNs` as the last call (a `.cached` reading) → the previous result, unchanged.
/// - Counter decrease (reset, recreated client, pid reuse) or `capturedNs` going back → nil + rebaseline.
///
/// This is the only place in the engine allowed to subtract counters (`&-` is banned elsewhere by CI grep).
public struct RateCalculator<Key: Hashable & Sendable>: Sendable {
    private struct State: Sendable {
        var counter: UInt64
        var capturedNs: UInt64
        var last: (delta: UInt64, seconds: Double)?
    }

    private var states: [Key: State] = [:]

    public init() {}

    public mutating func rate(for key: Key, counter: UInt64, capturedNs: UInt64) -> Double? {
        guard let d = delta(for: key, counter: counter, capturedNs: capturedNs), d.seconds > 0 else { return nil }
        return Double(d.delta) / d.seconds
    }

    public mutating func delta(for key: Key, counter: UInt64, capturedNs: UInt64) -> (delta: UInt64, seconds: Double)? {
        guard let prev = states[key] else {
            states[key] = State(counter: counter, capturedNs: capturedNs, last: nil)
            return nil
        }
        if capturedNs == prev.capturedNs { return prev.last }
        guard capturedNs > prev.capturedNs, counter >= prev.counter else {
            states[key] = State(counter: counter, capturedNs: capturedNs, last: nil)
            return nil
        }
        let result = (delta: counter &- prev.counter, seconds: Double(capturedNs &- prev.capturedNs) / 1e9)
        states[key] = State(counter: counter, capturedNs: capturedNs, last: result)
        return result
    }

    public mutating func prune(keeping live: Set<Key>) {
        for key in states.keys.filter({ !live.contains($0) }) { states[key] = nil }
    }

    public mutating func reset() {
        states.removeAll(keepingCapacity: true)
    }

    public var count: Int { states.count }
}
