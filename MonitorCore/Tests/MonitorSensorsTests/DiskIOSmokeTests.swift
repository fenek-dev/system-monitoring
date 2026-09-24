import Foundation
import Testing
@testable import MonitorSensors
import MonitorModel

/// Real-hardware smoke test (ARCHITECTURE §8, plan §0 "no sudo"). Gated behind `TELLTALE_HW_TESTS=1`
/// since it touches live IOKit state and shells out to `iostat`/`dd` for cross-checking.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
struct DiskIOSmokeTests {
    @Test func internalDriveIsPresentWithPlausibleCounters() throws {
        let sensor = DiskIOSensor()
        try sensor.prepare()
        let ctx = SampleContext()
        let (reading, _) = try sensor.sample(ctx)
        #expect(!reading.drivers.isEmpty)
        // At least one internal, non-ejectable driver (the boot SSD) should resolve a BSD name
        // (findings §1: a driver with no media child is a real but rare case, not every driver).
        let internalDrives = reading.drivers.filter(\.isInternal)
        #expect(!internalDrives.isEmpty)
        #expect(internalDrives.contains { $0.bsdName != nil })
    }

    /// Ref: `iostat -d -c 2 -w 1` and `dd if=/dev/zero of=<tmp> bs=1m count=512 && sync` (plan §0).
    /// Guards the counter delta (findings/extras.md §1: rates must use the measured elapsed time, and
    /// a counter that goes backwards — a replugged/recreated driver — must never underflow).
    @Test func writeIOGeneratedByDDIsObservedAsAPositiveByteDelta() throws {
        let sensor = DiskIOSensor()
        try sensor.prepare()
        let ctx = SampleContext()

        let (before, _) = try sensor.sample(ctx)
        let beforeByBSD = Dictionary(uniqueKeysWithValues: before.drivers.compactMap { d in d.bsdName.map { ($0, d) } })

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-w6d-smoke-\(UUID().uuidString).bin")
        let start = Date()
        let dd = Process()
        dd.executableURL = URL(fileURLWithPath: "/bin/dd")
        dd.arguments = ["if=/dev/zero", "of=\(tmpFile.path)", "bs=1m", "count=512"]
        dd.standardOutput = FileHandle.nullDevice
        dd.standardError = FileHandle.nullDevice
        try dd.run()
        dd.waitUntilExit()
        let sync = Process()
        sync.executableURL = URL(fileURLWithPath: "/bin/sync")
        try sync.run()
        sync.waitUntilExit()
        let elapsed = Date().timeIntervalSince(start)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let (after, _) = try sensor.sample(ctx)
        var sawPlausibleWriteDelta = false
        for driver in after.drivers {
            guard let bsdName = driver.bsdName, let prior = beforeByBSD[bsdName] else { continue }
            // Guard: a counter that decreased (driver reset/replug between samples, findings §1)
            // must never be read as a delta — skip that driver's contribution rather than underflow.
            guard driver.writeBytes >= prior.writeBytes else { continue }
            let deltaBytes = driver.writeBytes - prior.writeBytes
            if driver.isInternal, deltaBytes > 0 {
                sawPlausibleWriteDelta = true
                let mibPerSec = Double(deltaBytes) / 1_048_576 / elapsed
                #expect(mibPerSec > 0)
            }
        }
        #expect(sawPlausibleWriteDelta)
    }

    /// Perf is advisory (plan §0): report p50/p95, don't tune to it. The hard contract (ARCHITECTURE
    /// §5.4 Sensor.sample doc) is "never blocks > 250 ms"; ARCHITECTURE §7 estimates diskIO as part of
    /// a < 1 ms combined budget with hostCPU/memory/thermalState/interfaces.
    @Test func benchThirtySamples() throws {
        let sensor = DiskIOSensor()
        try sensor.prepare()
        let ctx = SampleContext()
        var samplesMs: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now()
            _ = try sensor.sample(ctx)
            samplesMs.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        samplesMs.sort()
        let p50 = samplesMs[samplesMs.count / 2]
        let p95 = samplesMs[Int(Double(samplesMs.count) * 0.95)]
        print("DiskIOSensor.sample() bench (n=30): p50=\(p50) ms, p95=\(p95) ms")
        #expect(p95 < 250)
    }
}
