import Foundation
import Testing
@testable import MonitorSensors
import MonitorModel

/// Real-hardware smoke test. Gated behind `TELLTALE_HW_TESTS=1` (plan §0: "no sudo" reference
/// checks; here vs `df -k /` and `diskutil info /`).
///
/// `.serialized`: avoids the same class of concurrent-hardware-access flakiness confirmed in
/// SMARTSmokeTests (Swift Testing runs a suite's tests concurrently by default).
@Suite(.serialized, .offCooperativePool, .enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
struct VolumeSmokeTests {
    @Test func rootVolumeMatchesDFAndDiskutil() throws {
        let sensor = VolumeSensor()
        try sensor.prepare()
        let (reading, _) = try sensor.sample(SampleContext())

        let root = try #require(reading.volumes.first { $0.id == "/" })
        #expect(root.isInternal)
        #expect(root.fsType == "apfs")

        // `df -k /`: 1024-byte blocks -> bytes. Allow slack: df's "Available" excludes some reserved
        // space df itself carves out, and both tools race a live, changing filesystem.
        let df = try Self.run("/bin/df", ["-k", "/"])
        let dfLine = try #require(df.split(separator: "\n").dropFirst().first)
        let fields = dfLine.split(separator: " ", omittingEmptySubsequences: true)
        let dfTotalBytes = try #require(UInt64(fields[1])) * 1024
        let dfAvailableBytes = try #require(UInt64(fields[3])) * 1024
        #expect(Self.withinTolerance(Double(root.totalBytes), Double(dfTotalBytes), fraction: 0.05))
        #expect(Self.withinTolerance(Double(root.availableBytes), Double(dfAvailableBytes), fraction: 0.05))

        // `diskutil info /`: Device Identifier + Protocol + Device Location + Encrypted, cross-checked
        // against the sensor's bsdName/busLabel/isInternal/isEncrypted (findings-style ASSERTED check).
        // Encryption is compared against the sensor's OWN isEncrypted, not a hardcoded expectation —
        // this machine's root volume happens to be unencrypted today, but that's incidental to what
        // the test is actually checking (the sensor agrees with diskutil), not the point of it.
        let diskutil = try Self.run("/usr/sbin/diskutil", ["info", "/"])
        #expect(Self.line(in: diskutil, labeled: "Device Identifier:", contains: root.bsdName ?? "?"))
        if let busLabel = root.busLabel {
            #expect(Self.line(in: diskutil, labeled: "Protocol:", contains: busLabel))
        }
        #expect(Self.line(in: diskutil, labeled: "Device Location:", contains: "Internal"))
        #expect(Self.line(in: diskutil, labeled: "Encrypted:", contains: root.isEncrypted ? "Yes" : "No"))
    }

    /// Perf is advisory (plan §0). VolumeSensor isn't in ARCHITECTURE §7's per-tick budget table (its
    /// cadence is 10 s/60 s, not every tick); the only hard contract is "never blocks > 250 ms".
    @Test func benchThirtySamples() throws {
        let sensor = VolumeSensor()
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
        print("VolumeSensor.sample() bench (n=30): p50=\(p50) ms, p95=\(p95) ms")
        #expect(p95 < 250)
    }

    private static func withinTolerance(_ a: Double, _ b: Double, fraction: Double) -> Bool {
        guard b != 0 else { return a == 0 }
        return abs(a - b) / b <= fraction
    }

    /// True if some line of `output` contains both `label` and `value` (diskutil right-pads the
    /// value column, so an exact-spacing match would be brittle).
    private static func line(in output: String, labeled label: String, contains value: String) -> Bool {
        output.split(separator: "\n").contains { $0.contains(label) && $0.contains(value) }
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
