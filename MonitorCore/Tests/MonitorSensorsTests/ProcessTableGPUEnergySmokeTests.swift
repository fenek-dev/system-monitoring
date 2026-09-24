import Darwin
import Foundation
import IOKit
import Metal
import Testing
@testable import MonitorSensors

/// T8 / ARCHITECTURE §10 open gap: does rusage v6 `ri_energy_nj` include GPU energy?
/// Same process, two 3 s windows: (A) one CPU thread spinning, (B) a Metal compute busy-loop (the
/// `spike-gpu-apps --load` kernel). Energy per CPU-second in A is the CPU-only rate; if B's energy is far above
/// B's CPU time × that rate while Metal's gpuStart/gpuEnd show the GPU busy with our work, GPU energy is counted.
/// Result 2026-09-24 (docs/icr/008-W6a-gpu-energy-term.md): it is NOT counted.
/// Hardware smoke tests are opt-in and run one suite at a time, at checkpoints (ruling). Measurements are
/// load-sensitive, so never run them in parallel with other suites or builds:
/// `TELLTALE_HW_TESTS=1 swift test --no-parallel --filter ProcessTableGPUEnergySmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized)
struct ProcessTableGPUEnergySmokeTests {
    struct Sample { var energyNJ: UInt64; var penergyNJ: UInt64; var cpuNs: UInt64; var gpuNs: UInt64; var t: UInt64 }

    static func sample() -> Sample? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        guard rc == 0 else { return nil }
        let tb = MachTimebase.current
        return Sample(energyNJ: ri.ri_energy_nj, penergyNJ: ri.ri_penergy_nj,
                      cpuNs: tb.nanoseconds(ri.ri_user_time) + tb.nanoseconds(ri.ri_system_time),
                      gpuNs: agxGPUNs(getpid()), t: w6aUptimeNs())
    }

    /// Σ AGX `AppUsage.accumulatedGPUTime` (ns) for clients created by `pid` (findings/gpu-apps.md).
    static func agxGPUNs(_ pid: Int32) -> UInt64 {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(svc, kIOServicePlane, &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var total: UInt64 = 0
        while case let c = IOIteratorNext(it), c != 0 {
            defer { IOObjectRelease(c) }
            guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, nil, 0)?
                    .takeRetainedValue() as? String, creator.hasPrefix("pid \(pid),") else { continue }
            let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, nil, 0)?.takeRetainedValue() as? [[String: Any]]
            for u in usage ?? [] { total += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
        }
        return total
    }

    static func delta(_ a: Sample, _ b: Sample) -> (joules: Double, pJoules: Double, cpuS: Double, gpuS: Double, wallS: Double)? {
        guard let e = w6aCounterDelta(b.energyNJ, a.energyNJ), let p = w6aCounterDelta(b.penergyNJ, a.penergyNJ),
              let c = w6aCounterDelta(b.cpuNs, a.cpuNs), let w = w6aCounterDelta(b.t, a.t) else { return nil }
        let g = w6aCounterDelta(b.gpuNs, a.gpuNs) ?? 0
        return (Double(e) / 1e9, Double(p) / 1e9, Double(c) / 1e9, Double(g) / 1e9, Double(w) / 1e9)
    }

    /// Returns Σ(gpuEndTime − gpuStartTime) of the completed command buffers (s), or nil on setup failure.
    static func runGPULoad(seconds: Double) -> Double? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
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
              let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
        let count = 1 << 20
        guard let buf = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: .storageModeShared) else { return nil }
        let w = pipeline.threadExecutionWidth
        let deadline = Date().addingTimeInterval(seconds)
        var inFlight: [MTLCommandBuffer] = []
        var busy = 0.0, errors = 0
        func retire(_ c: MTLCommandBuffer) {
            c.waitUntilCompleted()
            if c.status == .completed { busy += max(0, c.gpuEndTime - c.gpuStartTime) } else { errors += 1 }
        }
        while Date() < deadline {
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(buf, offset: 0, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: (count + w - 1) / w, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            inFlight.append(cmd)
            if inFlight.count > 4 { retire(inFlight.removeFirst()) }
        }
        inFlight.forEach(retire)
        if errors > 0 { print("W6a T8 command buffer errors: \(errors)") }
        return busy
    }

    @Test func energyIncludesGPU() throws {
        // A: CPU-only.
        let a0 = try #require(Self.sample())
        let end = w6aUptimeNs() + 3_000_000_000
        var x = 0.0
        while w6aUptimeNs() < end { x += 1 }
        #expect(x > 0)
        let a1 = try #require(Self.sample())
        // B: GPU load (warm up the pipeline first, outside the window).
        _ = try #require(Self.runGPULoad(seconds: 0.3))
        let b0 = try #require(Self.sample())
        let busy = try #require(Self.runGPULoad(seconds: 3))
        let b1 = try #require(Self.sample())
        let cpu = try #require(Self.delta(a0, a1)), gpu = try #require(Self.delta(b0, b1))
        let jPerCPUs = cpu.joules / max(cpu.cpuS, 1e-3)
        let expectedCPUOnly = gpu.cpuS * jPerCPUs
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        print("W6a T8 cpu-window: E=\(f(cpu.joules))J (P \(f(cpu.pJoules))J) cpu=\(f(cpu.cpuS))s wall=\(f(cpu.wallS))s → \(f(jPerCPUs)) J/cpu-s")
        print("W6a T8 gpu-window: E=\(f(gpu.joules))J (P \(f(gpu.pJoules))J) cpu=\(f(gpu.cpuS))s gpuBusy(Metal)=\(f(busy))s " +
              "gpu(AGX)=\(f(gpu.gpuS))s wall=\(f(gpu.wallS))s; CPU-only expectation \(f(expectedCPUOnly))J → " +
              "excess \(f(gpu.joules - expectedCPUOnly))J (\(f((gpu.joules - expectedCPUOnly) / gpu.wallS))W)")
        Thread.sleep(forTimeInterval: 2)
        print("W6a T8 AGX accumulatedGPUTime for our pid, 2 s after the load: \(f(Double(w6aCounterDelta(Self.agxGPUNs(getpid()), b0.gpuNs) ?? 0) / 1e9))s")
        // The GPU must have run our work for a meaningful part of the window (it is shared under machine load).
        #expect(busy > 0.5)
        // Pins the finding: fails if a future macOS starts billing GPU energy to ri_energy_nj (then drop ICR 008's term).
        // Load-aware bound. If GPU energy were included, a saturated M1 Max GPU (~20 W) would add ~64 J over a
        // 3.2 s window. Even a conservative 5 W floor adds ≥ 5 W × busy s. The threshold is half of that floor
        // (2.5 W × busy, ≈ 8 J at 3.1 s busy), so it scales with how long our kernel actually ran. It also allows
        // twice the CPU-only expectation, because J per CPU-second differs between P and E cores, and contention
        // can move our few ms of submit CPU. The old fixed 0.5 J bound flaked under parallel load; the observed
        // excess is ≤ 0 J.
        let bound = 2.5 * busy + 2 * expectedCPUOnly
        #expect(gpu.joules - expectedCPUOnly < bound)
    }
}
