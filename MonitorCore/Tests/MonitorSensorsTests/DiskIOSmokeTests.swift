import Foundation
import IOKit
import Testing
@testable import MonitorSensors
import MonitorModel

/// Real-hardware smoke test (ARCHITECTURE §8, plan §0 "no sudo"). Gated behind `TELLTALE_HW_TESTS=1`
/// since it touches live IOKit state and shells out to `iostat`/`dd` for cross-checking.
///
/// `.serialized`: the dd/iostat cross-check generates real disk I/O and measures it in a tight
/// window — running concurrently with another test in this suite (Swift Testing's default) would
/// pollute that measurement. See SMARTSmokeTests for a confirmed case of concurrent-hardware-access
/// flakiness in a sibling suite.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
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

    /// `ttIsDiskImageDriver` (review fix: mark disk-image drivers so a future aggregator can exclude
    /// them from system disk-I/O totals — not yet wired into `DiskIOReading`, see
    /// docs/icr/001-w6d-diskio-isdiskimage.md). This machine reliably has at least one mounted `.dmg`
    /// alongside the internal SSD, so both branches are exercised live, not just in principle.
    @Test func diskImageDriversAreDistinguishedFromRealHardware() throws {
        let drivers = ttEnumerateBlockStorageDrivers()
        defer { for driver in drivers { IOObjectRelease(driver) } }
        let internalDriver = try #require(drivers.first { ttMediaInfo(ofFirstChildOf: $0).isInternal })
        #expect(!ttIsDiskImageDriver(internalDriver))
        let diskImageDriver = try #require(drivers.first { ttIsDiskImageDriver($0) })
        #expect(!ttMediaInfo(ofFirstChildOf: diskImageDriver).isInternal)
    }

    /// Ref: `iostat -d -c 2 -w 1` and `dd if=/dev/zero of=<tmp> bs=1m count=512 && sync` (plan §0).
    /// `iostat`'s row 2 (the true `-w 1` one-second delta — row 1 is the since-boot average) is the
    /// independent ground truth; the sensor's own before/after bracket is timed to overlap that same
    /// one-second window as closely as a test process can. Genuinely ASSERTED, not tautological: this
    /// compares two independently-sourced numbers, not the sensor against itself.
    @Test func writeThroughputMatchesIostatWithinTolerance() throws {
        let sensor = DiskIOSensor()
        try sensor.prepare()
        let ctx = SampleContext()

        let (beforeAll, _) = try sensor.sample(ctx)
        let internalBSDName = try #require(beforeAll.drivers.first { $0.isInternal && $0.bsdName != nil }?.bsdName)
        let before = try #require(beforeAll.drivers.first { $0.bsdName == internalBSDName })

        // Start iostat first: its row 1 (since-boot average) prints within ~20 ms of launch
        // (measured), so a short fixed sleep reliably lands the dd write inside its `-w 1` window.
        let iostat = Process()
        iostat.executableURL = URL(fileURLWithPath: "/usr/sbin/iostat")
        iostat.arguments = ["-d", "-c", "2", "-w", "1"]
        let pipe = Pipe()
        iostat.standardOutput = pipe
        iostat.standardError = FileHandle.nullDevice
        try iostat.run()
        Thread.sleep(forTimeInterval: 0.15)

        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-w6d-smoke-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmpFile) }
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

        let iostatData = pipe.fileHandleForReading.readDataToEndOfFile()
        iostat.waitUntilExit()
        let iostatOutput = try #require(String(data: iostatData, encoding: .utf8))

        let (afterAll, _) = try sensor.sample(ctx)
        let after = try #require(afterAll.drivers.first { $0.bsdName == internalBSDName })

        // Production path, not a hand-rolled reset guard: over this short, controlled window the
        // driver cannot legitimately have reset, so a backwards counter is a real test failure.
        try #require(after.writeBytes >= before.writeBytes)
        let sensorBytes = Double(after.writeBytes - before.writeBytes)

        let (kbPerTransfer, transfersPerSecond) = try Self.iostatLastIntervalRow(iostatOutput, diskName: internalBSDName)
        let iostatBytes = kbPerTransfer * 1024 * transfersPerSecond // interval is 1s (-w 1)

        let tolerance = max(iostatBytes * 0.30, 5_000_000)
        #expect(
            abs(sensorBytes - iostatBytes) <= tolerance,
            "sensor delta \(sensorBytes) vs iostat \(iostatBytes) (tolerance \(tolerance))"
        )
    }

    /// Parses `iostat -d`'s `<diskName>` column group from the LAST data row (the true `-w N` interval
    /// delta; the first data row is the since-boot/since-last-reset average, not this call's window).
    private static func iostatLastIntervalRow(_ output: String, diskName: String) throws -> (kbPerTransfer: Double, transfersPerSecond: Double) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let headerLine = try #require(lines.first { $0.contains(diskName) })
        let diskNames = headerLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let diskIndex = try #require(diskNames.firstIndex(of: diskName))
        let dataLines = lines.dropFirst(2) // disk-name header + "KB/t tps MB/s ..." sub-header
        let lastDataLine = try #require(dataLines.last)
        let fields = lastDataLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let base = diskIndex * 3
        let kbPerTransfer = try #require(Double(fields[base]))
        let transfersPerSecond = try #require(Double(fields[base + 1]))
        return (kbPerTransfer, transfersPerSecond)
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
