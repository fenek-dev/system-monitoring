import Foundation
import Testing
@testable import MonitorModel

@Suite struct MetricVectorTests {
    private func encodeToDictionary(_ v: SystemMetrics) throws -> [String: Double] {
        let data = try JSONEncoder().encode(v)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Double])
    }

    @Test func subscriptStoresAndClearsValues() {
        var v = SystemMetrics()
        #expect(v[.cpuUsage] == nil)
        v[.cpuUsage] = 0.42
        v[.thermalPressure] = 2
        #expect(v[.cpuUsage] == 0.42)
        #expect(v[.thermalPressure] == 2)
        v[.cpuUsage] = nil
        #expect(v[.cpuUsage] == nil)
        v[.netRx] = .nan
        #expect(v[.netRx] == nil)
    }

    @Test func encodesAsKeyedObjectByRawValue() throws {
        var v = SystemMetrics()
        v[.cpuUsage] = 0.42
        v[.netRx] = 1_000
        #expect(try encodeToDictionary(v) == ["cpuUsage": 0.42, "netRx": 1_000])
    }

    @Test func roundTrips() throws {
        var v = SystemMetrics()
        v[.cpuUsage] = 0.42
        v[.memPressure] = 0.1
        v[.batteryPercent] = 87
        let decoded = try JSONDecoder().decode(SystemMetrics.self, from: JSONEncoder().encode(v))
        #expect(decoded == v)
        #expect(decoded[.batteryPercent] == 87)
    }

    @Test func decodesReorderedKeys() throws {
        let json = #"{"thermalPressure": 3, "netTx": 12.5, "cpuUsage": 0.25}"#
        let v = try JSONDecoder().decode(SystemMetrics.self, from: Data(json.utf8))
        #expect(v[.cpuUsage] == 0.25)
        #expect(v[.netTx] == 12.5)
        #expect(v[.thermalPressure] == 3)
        #expect(v[.netRx] == nil)
    }

    @Test func ignoresUnknownKeys() throws {
        let json = #"{"cpuUsage": 0.5, "quantumFlux": 1.0}"#
        let v = try JSONDecoder().decode(SystemMetrics.self, from: Data(json.utf8))
        var expected = SystemMetrics()
        expected[.cpuUsage] = 0.5
        #expect(v == expected)
    }

    @Test func omitsNaNSlots() throws {
        var v = AppMetrics()
        v[.cpu] = 12
        v[.gpu] = .nan
        let data = try JSONEncoder().encode(v)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Double])
        #expect(dict == ["cpu": 12])
        #expect(try encodeToDictionary(SystemMetrics()).isEmpty)
    }

    @Test func nanSlotsCompareAndHashEqual() {
        var a = SystemMetrics()
        var b = SystemMetrics()
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        a[.gpuUsage] = 0.3
        #expect(a != b)
        b[.gpuUsage] = 0.3
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }

    @Test func ordinalsCoverEveryCase() {
        #expect(HistoryMetric.ordinals.count == HistoryMetric.allCases.count)
        #expect(HistoryMetric.count == HistoryMetric.allCases.count)
        #expect(AppMetric.ordinals[.energy] == AppMetric.allCases.count - 1)
    }
}
