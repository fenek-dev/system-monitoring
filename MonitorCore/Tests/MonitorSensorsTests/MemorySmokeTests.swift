import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh MemorySmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized)
struct MemorySmokeTests {
    @Test func captureFixtures() throws {
        guard W6aFixture.capture else { return }
        let sensor = MemorySensor()
        try sensor.prepare()
        let raw = try MemoryFFI.raw(pageSize: MemoryFFI.pageSize(), total: MemoryFFI.sysctlValue("hw.memsize", UInt64.self) ?? 0,
                                    swapFiles: MemoryFFI.swapFileCount())
        let vm = try W6aFixture.run(["/usr/bin/vm_stat"])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(raw).write(to: W6aFixture.sourceURL("memory_raw.json"))
        try Data(vm.utf8).write(to: W6aFixture.sourceURL("vm_stat.txt"))
    }

    @Test func matchesVMStatSwapUsageAndMemoryPressure() throws {
        let sensor = MemorySensor()
        try sensor.prepare()
        let r = try sensor.sample(SampleContext()).reading
        let vm = VMStatText.parse(try W6aFixture.run(["/usr/bin/vm_stat"]))
        let swap = try W6aFixture.run(["/usr/sbin/sysctl", "-n", "vm.swapusage"])
        let mp = try W6aFixture.run(["/usr/bin/memory_pressure"])
        func mb(_ b: UInt64) -> String { "\(b >> 20)MB" }
        func near(_ bytes: UInt64, _ key: String) -> Bool {
            guard let pages = vm.pages[key] else { return false }
            let ref = Double(pages * vm.pageSize)
            return abs(Double(bytes) - ref) <= max(0.3 * ref, 64 * 1_048_576)
        }
        let swapUsedMB = swap.components(separatedBy: "used = ").dropFirst().first
            .flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) }
        let freePct = mp.components(separatedBy: "free percentage: ").dropFirst().first
            .flatMap { Double($0.prefix { $0.isNumber }) }
        print("W6a memory: total=\(mb(r.total)) active=\(mb(r.active)) inactive=\(mb(r.inactive)) wired=\(mb(r.wired)) " +
              "compressor=\(mb(r.compressorBytes)) stored=\(mb(r.compressedOriginalBytes ?? 0)) free=\(mb(r.free)) " +
              "swap=\(mb(r.swapUsed))/\(mb(r.swapTotal)) files=\(r.swapFileCount ?? -1) (sysctl used=\(swapUsedMB ?? -1)MB) " +
              "pressure=\(String(describing: r.pressureLevel)) fraction=\(r.pressureFraction ?? -1) (memory_pressure free=\(freePct ?? -1)%)")
        #expect(near(r.active, "Pages active"))
        #expect(near(r.inactive, "Pages inactive"))
        #expect(near(r.wired, "Pages wired down"))
        #expect(near(r.compressorBytes, "Pages occupied by compressor"))
        #expect(near(r.fileBacked, "File-backed pages"))
        #expect(near(r.anonymous, "Anonymous pages"))
        if let s = swapUsedMB { #expect(abs(Double(r.swapUsed) / 1_048_576 - s) <= max(0.3 * s, 64)) }
        if let f = freePct, let frac = r.pressureFraction { #expect(abs((1 - frac) * 100 - f) <= 5) }
        #expect(r.pressureLevel != nil)
        #expect(r.total == ProcessInfo.processInfo.physicalMemory)
    }

    @Test func bench() throws {
        let sensor = MemorySensor()
        try sensor.prepare()
        var ns: [UInt64] = []
        for _ in 0..<30 {
            let t = w6aUptimeNs()
            _ = try sensor.sample(SampleContext())
            ns.append(w6aUptimeNs() - t)
        }
        print("W6a bench memory \(W6aFixture.percentiles(ns))")
    }
}
