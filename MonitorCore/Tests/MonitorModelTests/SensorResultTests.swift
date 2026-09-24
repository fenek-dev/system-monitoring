import Foundation
import Testing
@testable import MonitorModel

@Suite struct SensorResultTests {
    private static let reading = LatencyReading(target: "1.1.1.1", lastRTTms: 12.5, minMs: 9, avgMs: 11, maxMs: 30)

    static let cases: [SensorResult<LatencyReading>] = [
        .fresh(reading, capturedNs: 1_000),
        .cached(reading, capturedNs: 2_000),
        .failed(.posix(5, "sysctl"), last: reading, capturedNs: 3_000),
        .failed(.timeout, last: nil, capturedNs: nil),
        .notRequested,
    ]

    @Test(arguments: cases)
    func roundTrips(_ result: SensorResult<LatencyReading>) throws {
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SensorResult<LatencyReading>.self, from: data)
        #expect(same(decoded, result))
    }

    @Test func accessors() {
        let r = Self.reading
        #expect(SensorResult.fresh(r, capturedNs: 1).value == r)
        #expect(SensorResult.fresh(r, capturedNs: 1).capturedNs == 1)
        #expect(SensorResult.cached(r, capturedNs: 2).value == r)
        #expect(SensorResult.cached(r, capturedNs: 2).capturedNs == 2)
        #expect(SensorResult.failed(.timeout, last: r, capturedNs: 3).value == r)
        #expect(SensorResult.failed(.timeout, last: r, capturedNs: 3).capturedNs == 3)
        #expect(SensorResult<LatencyReading>.failed(.timeout, last: nil, capturedNs: nil).value == nil)
        #expect(SensorResult<LatencyReading>.notRequested.value == nil)
        #expect(SensorResult<LatencyReading>.notRequested.capturedNs == nil)
    }
}

/// Structural equality (SensorResult is intentionally not Equatable in the model).
func same<R: Equatable>(_ a: SensorResult<R>, _ b: SensorResult<R>) -> Bool {
    switch (a, b) {
    case let (.fresh(x, n1), .fresh(y, n2)), let (.cached(x, n1), .cached(y, n2)):
        x == y && n1 == n2
    case let (.failed(e1, l1, n1), .failed(e2, l2, n2)):
        e1 == e2 && l1 == l2 && n1 == n2
    case (.notRequested, .notRequested):
        true
    default:
        false
    }
}
