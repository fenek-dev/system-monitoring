import Foundation
import Testing
@testable import MonitorSensors
import MonitorModel

/// Real-hardware smoke test. Gated behind `TELLTALE_HW_TESTS=1`; cross-checked against
/// `/opt/homebrew/bin/smartctl -a disk0` (no sudo — smartmontools 7.2 reads NVMe SMART unprivileged
/// on Apple Silicon's internal SSD, per findings/extras.md §2).
///
/// `.serialized`: Swift Testing runs a suite's tests concurrently by default, but two threads
/// simultaneously driving the NVMeSMARTLib CFPlugIn's create/query/read/destroy dance on the same
/// physical controller is a genuine race (confirmed: `benchThirtySamples` passes reliably alone, but
/// intermittently threw `.unavailable` when run alongside `matchesSmartctlOnTheInternalSSD`). Not a
/// production concern — `SensorSlot` only ever drives one sensor instance from one sampler executor.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1"))
struct SMARTSmokeTests {
    @Test func matchesSmartctlOnTheInternalSSD() throws {
        let smartctlPath = "/opt/homebrew/bin/smartctl"
        try #require(FileManager.default.isExecutableFile(atPath: smartctlPath))

        let sensor = SMARTSensor()
        try sensor.prepare()
        let (info, _) = try sensor.sample(SampleContext())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: smartctlPath)
        process.arguments = ["-a", "disk0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        let smartctlPowerOnHours = try Self.extractInt(from: output, label: "Power On Hours:")
        let smartctlUnsafeShutdowns = try Self.extractInt(from: output, label: "Unsafe Shutdowns:")
        let smartctlPercentageUsed = try Self.extractInt(from: output, label: "Percentage Used:")
        let smartctlModel = try Self.extractString(from: output, label: "Model Number:")

        // Power-on hours and unsafe shutdowns are monotonic counters that only change on
        // power-cycle/shutdown events, so they should match exactly (findings §2).
        #expect(info.powerOnHours == smartctlPowerOnHours)
        #expect(info.unsafeShutdowns == smartctlUnsafeShutdowns)
        #expect(Int(info.percentageUsed ?? -1) == smartctlPercentageUsed)
        #expect(info.status == .healthy)
        #expect(info.model == smartctlModel)
        if let temperatureC = info.temperatureC {
            // Both readings are live and taken seconds apart; findings §2 saw a few degrees of drift.
            #expect(temperatureC > 0 && temperatureC < 100)
        }

        // Capacity cross-checked against `diskutil info disk0`'s "Disk Size: ... (<n> Bytes)".
        let diskutilInfo = try Self.run("/usr/sbin/diskutil", ["info", "disk0"])
        let sizeLine = try #require(diskutilInfo.split(separator: "\n").first { $0.contains("Disk Size:") })
        let bytesText = try #require(sizeLine.split(separator: "(").dropFirst().first?.split(separator: " ").first)
        let diskutilCapacityBytes = try #require(UInt64(bytesText))
        #expect(info.capacityBytes == diskutilCapacityBytes)
    }

    /// Perf is advisory (plan §0). Each sample() opens+reads+closes the CFPlugIn fresh (findings §2:
    /// ~0.6 ms targeted lookup + ~2-3 ms SMARTReadData) — cheap enough at this sensor's 300 s,
    /// .smart-demand-gated cadence that keeping the plugin open between reads isn't worth the
    /// non-Sendable-handle complexity. The hard contract is "never blocks > 250 ms".
    @Test func benchThirtySamples() throws {
        let sensor = SMARTSensor()
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
        print("SMARTSensor.sample() bench (n=30): p50=\(p50) ms, p95=\(p95) ms")
        #expect(p95 < 250)
    }

    private static func extractInt(from output: String, label: String) throws -> Int {
        let cleaned = try Self.extractString(from: output, label: label).filter { $0.isNumber }
        return try #require(Int(cleaned))
    }

    private static func extractString(from output: String, label: String) throws -> String {
        let line = try #require(output.split(separator: "\n").first { $0.contains(label) })
        let afterLabel = try #require(line.range(of: label)).upperBound
        return line[afterLabel...].trimmingCharacters(in: .whitespaces)
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
