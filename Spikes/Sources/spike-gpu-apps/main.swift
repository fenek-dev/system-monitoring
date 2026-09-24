import Foundation
import IOKit
import Metal
import CPrivate

func props(_ e: io_registry_entry_t) -> [String: Any] {
    var u: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(e, &u, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = u?.takeRetainedValue() else { return [:] }
    return d as? [String: Any] ?? [:]
}

// MARK: - optional GPU load generator (--load), since we can't open a browser here.
// Runs a busy MTLComputeCommandEncoder loop on a background thread for `seconds`,
// so this process's own PID should show up in the AGX client walk with nonzero GPU %.
func runGPULoad(seconds: Double) {
    guard let device = MTLCreateSystemDefaultDevice() else { print("[load] no Metal device"); return }
    guard let queue = device.makeCommandQueue() else { print("[load] no command queue"); return }
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void busy(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float v = buf[id];
        for (int i = 0; i < 20000; i++) { v = v * 1.0000001f + 0.0000001f; }
        buf[id] = v;
    }
    """
    guard let lib = try? device.makeLibrary(source: src, options: nil),
          let fn = lib.makeFunction(name: "busy"),
          let pipeline = try? device.makeComputePipelineState(function: fn) else {
        print("[load] failed to build Metal pipeline"); return
    }
    let count = 1 << 20
    guard let buf = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: .storageModeShared) else {
        print("[load] failed to allocate buffer"); return
    }
    let w = pipeline.threadExecutionWidth
    let tg = MTLSize(width: w, height: 1, depth: 1)
    let groups = MTLSize(width: (count + w - 1) / w, height: 1, depth: 1)

    print("[load] starting Metal compute busy-loop for \(seconds)s, pid=\(getpid())")
    let deadline = Date().addingTimeInterval(seconds)
    var inFlight: [MTLCommandBuffer] = []
    while Date() < deadline {
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { break }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        inFlight.append(cmd)
        if inFlight.count > 4 { inFlight.removeFirst().waitUntilCompleted() }
    }
    inFlight.forEach { $0.waitUntilCompleted() }
    print("[load] done")
}

if CommandLine.arguments.contains("--load") {
    let t = Thread { runGPULoad(seconds: 5) }
    t.start()
    Thread.sleep(forTimeInterval: 0.3) // let the device/queue/pipeline stand up before we start sampling
}

let accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
guard accel != 0 else { print("no AGXAccelerator"); exit(1) }

let perf = props(accel)["PerformanceStatistics"] as? [String: Any] ?? [:]
print("PerformanceStatistics keys:", perf.keys.sorted().joined(separator: ", "))
print("Device Utilization %:", perf["Device Utilization %"] ?? "–")

// Design wants: device utilization, renderer/tiler utilization, in-use system memory,
// and anything about GPU memory. We don't know the exact key spelling ahead of time
// (private/undocumented dict), so print every key that plausibly matches by substring.
let interesting = ["utiliz", "memory", "mem", "gpu", "alloc", "vram"]
print("\n-- keys matching utilization/memory/gpu --")
for k in perf.keys.sorted() {
    let lk = k.lowercased()
    if interesting.contains(where: { lk.contains($0) }) {
        print("  \(k): \(perf[k] ?? "–")")
    }
}
print("")

/// pid -> (name, accumulated GPU ns)
func gpuTimes(dumpFirst: Bool) -> [Int32: (String, UInt64)] {
    var out: [Int32: (String, UInt64)] = [:]
    var it: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &it) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(it) }
    var dumped = !dumpFirst
    while case let child = IOIteratorNext(it), child != 0 {
        defer { IOObjectRelease(child) }
        let p = props(child)
        guard let creator = p["IOUserClientCreator"] as? String else { continue }  // "pid 123, Name"
        if !dumped, p["AppUsage"] != nil { print("sample client props:", p.keys.sorted().joined(separator: ", ")); dumped = true }
        let pidStr = creator.split(separator: ",").first?.split(separator: " ").last
        guard let pid = pidStr.flatMap({ Int32($0) }) else { continue }
        let name = creator.split(separator: ",", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?"
        let usage = p["AppUsage"] as? [[String: Any]] ?? []
        let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
        out[pid, default: (name, 0)].1 += ns
    }
    return out
}

let clock = ContinuousClock()
var a: [Int32: (String, UInt64)] = [:]
let cost = clock.measure { a = gpuTimes(dumpFirst: true) }
Thread.sleep(forTimeInterval: 1)
let b = gpuTimes(dumpFirst: false)
print("clients(pids)=\(a.count) walkCost=\(cost)")
let rows = b.compactMap { pid, v -> (String, Double)? in
    guard let old = a[pid] else { return nil }
    return ("\(v.0) [\(pid)]", Double(v.1 &- old.1) / 1e9 * 100)   // % of one GPU over 1 s
}.sorted { $0.1 > $1.1 }
for (n, pct) in rows.prefix(10) { print(n.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "%6.1f %%", pct)) }

// Responsible-PID grouping check: does the AGX client creator PID equal the pid macOS
// attributes resource use to, or is it a helper process (e.g. a browser renderer/GPU
// process) that should be collapsed into its parent app for per-app GPU accounting?
print("\n-- responsible-PID check (creator pid -> responsible pid) --")
for (pid, v) in b.sorted(by: { $0.value.1 > $1.value.1 }).prefix(10) {
    let resp = responsibility_get_pid_responsible_for_pid(pid)
    let mark = (resp > 0 && resp != pid) ? "  <-- DIFFERS, needs grouping" : ""
    print("  \(v.0) [\(pid)] -> responsible pid \(resp)\(mark)")
}
