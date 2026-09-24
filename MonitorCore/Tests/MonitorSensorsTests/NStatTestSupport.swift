import Darwin
import Foundation

/// W6c hardware-test helpers. Smoke suites run with `TELLTALE_HW_TESTS=1`; fixture capture with
/// `TELLTALE_CAPTURE=1` (writes into the source tree's `Fixtures/W6c/`); the 3-minute soak with `TELLTALE_SOAK=1`.
enum W6cFixture {
    static let env = ProcessInfo.processInfo.environment
    static let hardwareTests = env["TELLTALE_HW_TESTS"] == "1"
    static let capture = env["TELLTALE_CAPTURE"] == "1"
    static let soak = env["TELLTALE_SOAK"] == "1"

    /// Fixture in the test bundle.
    static func url(_ name: String) throws -> URL {
        guard let base = Bundle.module.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        return base.appendingPathComponent("Fixtures/W6c/\(name)")
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// Source-tree location (capture mode).
    static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/W6c/\(name)")
    }

    /// Runs a tool and returns stdout (stderr discarded).
    @discardableResult
    static func run(_ argv: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func spawn(_ argv: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Local HTTP server (`python3 -m http.server`) over a temp dir holding `big.bin` (`bigMB` MiB) and
    /// `small.bin` (100 KiB). Local traffic only: external downloads may be blocked.
    struct HTTPServer {
        let process: Process
        let port: Int
        let dir: URL
        var pid: Int32 { process.processIdentifier }
        func stop() {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func startHTTPServer(bigMB: Int = 64) throws -> HTTPServer {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w6c-http-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: bigMB << 20).write(to: dir.appendingPathComponent("big.bin"))
        try Data(count: 100 << 10).write(to: dir.appendingPathComponent("small.bin"))
        let port = Int.random(in: 20_000...40_000)
        let p = try spawn(["/usr/bin/python3", "-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", dir.path])
        for _ in 0..<50 {
            usleep(100_000)
            let code = try run(["/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:\(port)/small.bin"])
            if code == "200" { return HTTPServer(process: p, port: port, dir: dir) }
        }
        p.terminate()
        throw CocoaError(.fileReadUnknown)
    }

    /// `nettop -P -L 1 -J bytes_in,bytes_out` → pid → (in, out) cumulative bytes.
    static func nettopTotals() throws -> [Int32: (rx: UInt64, tx: UInt64)] {
        let text = try run(["/usr/bin/nettop", "-P", "-L", "1", "-J", "bytes_in,bytes_out"])
        var out: [Int32: (UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = Int32(cols[0][cols[0].index(after: dot)...]),
                  let rx = UInt64(cols[1]), let tx = UInt64(cols[2]) else { continue }
            out[pid] = (rx, tx)
        }
        return out
    }

    static func cpuTimeNs() -> UInt64 {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        func ns(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1_000 }
        return ns(ru.ru_utime) + ns(ru.ru_stime)
    }

    /// Resident size of this process (bytes).
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let s = values.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    /// `b - a`, 0 if the counter went backwards (guarded delta).
    static func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { b >= a ? b - a : 0 }

    static func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
}
