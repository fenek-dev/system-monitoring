import Foundation
import os
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Parse layer on a captured HID read (`Fixtures/W6b/hid_samples.json`, M1 Max, 63 live services).
struct HIDParseTests {
    private let catalog = try! TemperatureCatalog.bundled()

    @Test func capturedServicesDedupeAndGroup() throws {
        let samples = try W6bFixture.decode("hid_samples.json", as: [HIDTemperatureParse.Sample].self)
        #expect(samples.count > 50)
        let r = HIDTemperatureParse.reading(samples, catalog: catalog).sensors
        let names = Set(samples.map(\.name))
        #expect(r.count == names.count - 1)                          // minus PMU tcal
        #expect(r.map(\.name) == r.map(\.name).sorted())
        #expect(r.first { $0.name == "NAND CH0 temp" }?.group == .ssd)
        #expect(r.first { $0.name == "gas gauge battery" }?.group == .battery)
        #expect(r.filter { $0.group == .soc }.count >= 20)
        #expect(!r.contains { $0.group == .cpuPerformance || $0.group == .cpuEfficiency || $0.group == .gpu })
        // duplicate services are averaged, not first-wins
        let dup = samples.filter { $0.name == "PMU tdie1" }.map(\.celsius)
        #expect(dup.count >= 2)
        let tdie1 = try #require(r.first { $0.name == "PMU tdie1" })
        #expect(abs(tdie1.celsius - dup.reduce(0, +) / Double(dup.count)) < 1e-9)
    }

    /// `sample()` must never wait for the (68–94 ms, up to 250 ms) read: it kicks it off and returns at once.
    @Test func sampleNeverBlocksOnTheRead() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let sensor = HIDTemperatureSensor(reader: {
            let n = calls.withLock { $0 += 1; return $0 }
            Thread.sleep(forTimeInterval: 0.3)                               // slow read
            return .success([.init(name: "NAND CH0 temp", celsius: 30 + Double(n))])
        })
        try sensor.prepare()
        func timed<T>(_ f: () throws -> T) rethrows -> (T, Double) {
            let t = w6bUptimeNs(); let v = try f(); return (v, Double(w6bUptimeNs() - t) / 1e6)
        }
        // 1. no reading yet → .transient("warming up"), immediately
        let (first, firstMs) = timed { Result { () throws(SensorError) in try sensor.sample(SampleContext()) } }
        #expect(firstMs < 20, "first sample blocked \(firstMs) ms")
        if case .failure(let e) = first { #expect(e == .transient("warming up")) } else { Issue.record("expected warming up") }
        // 2. after the read lands → that reading; a new read is kicked but not awaited
        #expect(await sensor.waitForRead(after: 0))
        let (second, secondMs) = try timed { try sensor.sample(SampleContext()) }
        #expect(secondMs < 20)
        #expect(second.reading.sensors.first?.celsius == 31)
        // 3. stale reading while the next read is in flight → the stale one, immediately (same capturedNs)
        let (third, thirdMs) = try timed { try sensor.sample(SampleContext()) }
        #expect(thirdMs < 20 && third.capturedNs == second.capturedNs)
        #expect(await sensor.waitForRead(after: second.capturedNs))
        #expect(try sensor.sample(SampleContext()).reading.sensors.first?.celsius == 32)
        #expect(calls.withLock { $0 } <= 3)                                  // no read stacking
    }

    /// S-M5: a read hung past its deadline is reported (→ `.timeout`, never the stale reading as fresh), and no
    /// second read is stacked behind it.
    @Test func hungReadIsReportedAfterDeadline() async throws {
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let box = HIDTemperatureBox(catalog: nil) {
            calls.withLock { $0 += 1 }
            release.wait()                                                  // hung IOHIDServiceClientCopyEvent
            return .success([.init(name: "NAND CH0 temp", celsius: 30)])
        }
        defer { release.signal() }
        let s: UInt64 = 1_000_000_000
        #expect(!box.kick(nowNs: 100 * s).stalled)                          // starts the read
        #expect(!box.kick(nowNs: 105 * s).stalled)
        #expect(box.kick(nowNs: 111 * s).stalled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func readErrorBeforeFirstReadingIsThrown() async throws {
        let sensor = HIDTemperatureSensor(reader: { .failure(.unavailable("no HID temperature services")) })
        try sensor.prepare()
        _ = try? sensor.sample(SampleContext())
        try await Task.sleep(for: .milliseconds(100))
        #expect(throws: SensorError.unavailable("no HID temperature services")) { try sensor.sample(SampleContext()) }
    }

    @Test func filtersGarbage() {
        let s: [HIDTemperatureParse.Sample] = [
            .init(name: "PMU tdie0", celsius: 50), .init(name: "PMU tdie0", celsius: 52),
            .init(name: "PMU tdie9", celsius: .nan), .init(name: "PMU tdev1", celsius: -100),
            .init(name: "", celsius: 40), .init(name: "PMU tcal", celsius: 51), .init(name: "Mystery", celsius: 33),
        ]
        let r = HIDTemperatureParse.reading(s, catalog: catalog).sensors
        #expect(r.map(\.name) == ["Mystery", "PMU tdie0"])
        #expect(r.map(\.celsius) == [33, 51])
        #expect(r.map(\.group) == [.other, .soc])
        #expect(HIDTemperatureParse.reading(s, catalog: nil).sensors.allSatisfy { $0.group == .other })
    }
}
