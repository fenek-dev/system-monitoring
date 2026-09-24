import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh HIDSmokeTests`.
@Suite(.enabled(if: W6bFixture.hardwareTests), .serialized, .w6bExclusive)
struct HIDSmokeTests {
    @Test func rawListVsSmartctlAndBatteryAndSMC() async throws {
        if W6bFixture.capture, case let .success(samples) = HIDTemperatureBox.readAll() {
            try W6bFixture.write(samples, "hid_samples.json")
        }
        let sensor = HIDTemperatureSensor()
        try sensor.prepare()
        // First sample: never blocks, kicks the read and reports .transient("warming up").
        let t0 = w6bUptimeNs()
        #expect(throws: SensorError.transient("warming up")) { try sensor.sample(SampleContext(demand: .rawTemperatures)) }
        let firstMs = Double(w6bUptimeNs() - t0) / 1e6
        #expect(await sensor.waitForRead(after: 0))
        let readMs = Double(w6bUptimeNs() - t0) / 1e6
        let t1 = w6bUptimeNs()
        let first = try sensor.sample(SampleContext(demand: .rawTemperatures))
        let secondMs = Double(w6bUptimeNs() - t1) / 1e6
        let r = first.reading.sensors
        func avg(_ g: TemperatureGroup) -> Double? {
            let v = r.filter { $0.group == g }.map(\.celsius)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let smart = (try? W6bFixture.run(["/opt/homebrew/bin/smartctl", "-a", "disk0"])) ?? ""
        let smartC = smart.split(separator: "\n").first { $0.hasPrefix("Temperature:") }
            .flatMap { Double($0.split(separator: " ").dropFirst().first ?? "") }
        let ioreg = try W6bFixture.run(["/usr/sbin/ioreg", "-rn", "AppleSmartBattery"])
        let hasBattery = ioreg.contains("AppleSmartBattery")               // desktops: no battery checks
        // HID "gas gauge battery" tracks ioreg VirtualTemperature (and SMC TB?T); ioreg `Temperature` reads ~4 °C lower.
        let battC = ioreg.split(separator: "\n").first { $0.contains("\"VirtualTemperature\" = ") }
            .flatMap { Double($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }.map { $0 / 100 }
        let smc = SMCSensor()
        try smc.prepare()
        defer { smc.invalidate() }
        let tbt = try smc.sample(SampleContext()).reading.temperatures.filter { $0.group == .battery }.map(\.celsius)
        let smcBatt = tbt.isEmpty ? nil : tbt.reduce(0, +) / Double(tbt.count)
        print(String(format: "W6b hid: n=%d first=%.2fms read=%.1fms second=%.2fms ssd=%.1f (smartctl %.0f) battery=%.1f (ioreg %.1f, SMC TB?T %.1f) soc=%.1f",
                     r.count, firstMs, readMs, secondMs, avg(.ssd) ?? -1, smartC ?? -1, avg(.battery) ?? -1, battC ?? -1,
                     smcBatt ?? -1, avg(.soc) ?? -1))
        #expect(r.count >= 20)
        #expect(Set(r.map(\.name)).count == r.count)                 // duplicates averaged
        #expect(!r.contains { $0.name == "PMU tcal" })
        #expect(r.allSatisfy { $0.source == .hid })
        #expect(firstMs < 10)                                          // never waits for the read
        #expect(secondMs < 5)
        let ssd = try #require(avg(.ssd))
        if let smartC { #expect(abs(ssd - smartC) <= 5, "HID NAND \(ssd) vs smartctl \(smartC)") }
        if hasBattery {
            let batt = try #require(avg(.battery))
            if let battC { #expect(abs(batt - battC) <= 3) }
            if let smcBatt { #expect(abs(batt - smcBatt) <= 3) }
        }
    }

    @Test func bench() async throws {
        var ns: [UInt64] = []
        for _ in 0..<10 {
            let t = w6bUptimeNs()
            _ = HIDTemperatureBox.readAll()
            ns.append(w6bUptimeNs() - t)
        }
        let sensor = HIDTemperatureSensor()
        try sensor.prepare()
        _ = try? sensor.sample(SampleContext())                  // warming up
        #expect(await sensor.waitForRead(after: 0))
        var call: [UInt64] = []
        for _ in 0..<30 {
            let t = w6bUptimeNs()
            _ = try sensor.sample(SampleContext())
            call.append(w6bUptimeNs() - t)
        }
        print("W6b bench hid read(off-queue) \(w6bPercentiles(ns)); sample() \(w6bPercentiles(call))")
    }
}
