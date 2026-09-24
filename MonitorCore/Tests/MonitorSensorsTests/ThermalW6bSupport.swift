import Foundation
import Metal
import os

/// W6b fixtures: `Tests/MonitorSensorsTests/Fixtures/W6b/`. Read from the test bundle; written (capture mode,
/// `TELLTALE_W6B_CAPTURE=1`) to the source tree so they can be committed.
enum W6bFixture {
    static func url(_ name: String) throws -> URL {
        guard let base = Bundle.module.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        return base.appendingPathComponent("Fixtures/W6b/\(name)")
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func decode<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static func sourceURL(_ name: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("Fixtures/W6b/\(name)")
    }

    static func write<T: Encodable>(_ value: T, _ name: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: sourceURL(name))
    }

    static var hardwareTests: Bool { ProcessInfo.processInfo.environment["TELLTALE_HW_TESTS"] == "1" }
    static var capture: Bool { ProcessInfo.processInfo.environment["TELLTALE_W6B_CAPTURE"] == "1" }

    /// Runs `argv`, returns stdout.
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

    /// n × `yes > /dev/null` children, optionally at background QoS (`taskpolicy -c background` → E-cores).
    /// Always pair with `stop(_:)` (kills exactly these pids, never `killall`).
    static func startYes(_ n: Int, background: Bool = false) throws -> [Process] {
        try (0..<n).map { _ in
            let p = Process()
            if background {
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
                p.arguments = ["-c", "background", "/usr/bin/yes"]
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            return p
        }
    }

    static func stop(_ procs: [Process]) {
        for p in procs where p.isRunning { p.terminate() }
        for p in procs { p.waitUntilExit() }
    }

    static func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

/// In-process Metal compute busy loop (same kernel as `spike-gpu-apps --load`). Runs until `stop()`.
final class W6bGPULoad: Sendable {
    private let running = OSAllocatedUnfairLock(initialState: true)

    /// nil when Metal is unavailable. Metal objects are created on the load thread (no cross-thread sharing).
    static func start() -> W6bGPULoad? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        let load = W6bGPULoad()
        let t = Thread { load.loop() }
        t.start()
        return load
    }

    private func loop() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void busy(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float v = buf[id];
            for (int i = 0; i < 20000; i++) { v = v * 1.0000001f + 0.0000001f; }
            buf[id] = v;
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil), let fn = lib.makeFunction(name: "busy"),
              let pipeline = try? device.makeComputePipelineState(function: fn),
              let buf = device.makeBuffer(length: (1 << 20) * 4, options: .storageModeShared) else { return }
        let w = pipeline.threadExecutionWidth
        do {
            var inFlight: [MTLCommandBuffer] = []
            while isRunning {
                guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { break }
                enc.setComputePipelineState(pipeline)
                enc.setBuffer(buf, offset: 0, index: 0)
                enc.dispatchThreadgroups(MTLSize(width: ((1 << 20) + w - 1) / w, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
                enc.endEncoding()
                cmd.commit()
                inFlight.append(cmd)
                if inFlight.count > 4 { inFlight.removeFirst().waitUntilCompleted() }
            }
            inFlight.forEach { $0.waitUntilCompleted() }
        }
    }

    var isRunning: Bool { running.withLock { $0 } }

    func stop() {
        running.withLock { $0 = false }
        Thread.sleep(forTimeInterval: 0.3)
    }
}
