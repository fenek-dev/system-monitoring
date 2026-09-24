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

    static func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }

    /// p50/p95 of nanosecond samples, formatted in ms.
    static func percentiles(_ samples: [UInt64]) -> String {
        let s = samples.sorted()
        guard !s.isEmpty else { return "n/a" }
        let p50 = s[s.count / 2], p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        return "p50=\(ms(p50))ms p95=\(ms(p95))ms n=\(s.count)"
    }
}
