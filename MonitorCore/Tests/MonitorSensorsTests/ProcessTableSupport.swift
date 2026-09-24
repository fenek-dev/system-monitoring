import Foundation

/// W6a fixtures: `Tests/MonitorSensorsTests/Fixtures/W6a/`. Read from the test bundle; written (capture mode) to
/// the source tree so they can be committed.
enum W6aFixture {
    static func url(_ name: String) throws -> URL {
        guard let base = Bundle.module.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        return base.appendingPathComponent("Fixtures/W6a/\(name)")
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func string(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    /// Source-tree directory for capture runs.
    static func sourceURL(_ name: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("Fixtures/W6a/\(name)")
    }

    static var hardwareTests: Bool { ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1" }
    static var capture: Bool { ProcessInfo.processInfo.environment["TELLTALE_W6A_CAPTURE"] == "1" }

    /// Runs `argv` and returns stdout (reference tools for smoke tests).
    static func run(_ argv: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `yes > /dev/null` child (~100 % of one core). Caller terminates it.
    static func spawnYes() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Last `%CPU` value `top -l N -pid <pid> -stats pid,cpu` printed for `pid`.
    static func topValue(_ output: String, pid: Int32) -> Double? {
        output.split(separator: "\n").reversed().lazy.compactMap { line -> Double? in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, Int32(f[0]) == pid else { return nil }
            return Double(f[1])
        }.first
    }

    /// Cumulative CPU seconds from `ps -o time= -p <pid>` ("M:SS.cc" or "H:MM:SS.cc").
    static func psCPUSeconds(_ pid: Int32) throws -> Double? {
        let s = try run(["/bin/ps", "-o", "time=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == s.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// user+sys % from the last "CPU usage" line of `top -l N -n 0`, scaled to % of one core.
    static func topTotalCores(_ output: String) -> Double? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("CPU usage") }) else { return nil }
        let nums = line.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard nums.count >= 2 else { return nil }
        return (nums[0] + nums[1]) * Double(ProcessInfo.processInfo.activeProcessorCount)
    }

    static func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }

    /// p50/p95 of nanosecond samples, formatted in ms.
    static func percentiles(_ samples: [UInt64]) -> String {
        let s = samples.sorted()
        guard !s.isEmpty else { return "n/a" }
        let p50 = s[s.count / 2], p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        return "p50=\(ms(p50))ms p95=\(ms(p95))ms n=\(s.count)"
    }
}
