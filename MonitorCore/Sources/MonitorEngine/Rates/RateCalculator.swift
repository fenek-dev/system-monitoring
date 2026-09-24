import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

/// Counter deltas → per-second rates, timed by capturedNs. First sight → nil; counter decrease (reset/recreated
/// client/pid reuse) → nil + rebaseline; same capturedNs as last call → returns the previous result unchanged.
public struct RateCalculator<Key: Hashable & Sendable>: Sendable {
    public init() {}
    public mutating func rate(for key: Key, counter: UInt64, capturedNs: UInt64) -> Double? { nil }
    public mutating func delta(for key: Key, counter: UInt64, capturedNs: UInt64) -> (delta: UInt64, seconds: Double)? { nil }
    public mutating func prune(keeping live: Set<Key>) {}
    public mutating func reset() {}
    public var count: Int { 0 }
}
