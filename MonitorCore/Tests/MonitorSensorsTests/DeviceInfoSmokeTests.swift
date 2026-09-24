import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Hardware smoke: opt-in, run one suite at a time at checkpoints; never in parallel with other suites or builds
/// (load-sensitive). `TELLTALE_HW_TESTS=1 swift test --no-parallel --filter DeviceInfoSmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized, .offCooperativePool)
struct DeviceInfoSmokeTests {
    @Test func captureRaw() throws {
        guard W6aFixture.capture else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(DeviceInfoFFI.raw()).write(to: W6aFixture.sourceURL("device_raw.json"))
    }

    @Test func matchesSystemProfilerAndSysctl() throws {
        let t = w6aUptimeNs()
        let d = try DeviceInfoSensor().sample(SampleContext()).reading
        let cost = w6aUptimeNs() - t
        let sp = try W6aFixture.run(["/usr/sbin/system_profiler", "SPHardwareDataType"])
        func field(_ key: String) -> String? {
            sp.split(separator: "\n").first { $0.contains("\(key):") }
                .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        }
        print("W6a device: \(d.modelName) | \(d.hwModel) | \(d.chipName) \(d.performanceCores)P+\(d.efficiencyCores)E " +
              "GPU \(d.gpuCores ?? -1) ANE \(d.neuralEngineCores ?? -1) | \(d.memoryBytes >> 30) GB \(d.memoryType ?? "-") " +
              "\(d.memoryBandwidth ?? "-") | \(d.osVersion) (\(d.osBuild)) | boot \(d.bootTime) | battery \(d.hasBattery) " +
              "fans \(d.fanCount) | cost \(W6aFixture.ms(cost))ms")
        print("W6a system_profiler: model=\(field("Model Name") ?? "-") id=\(field("Model Identifier") ?? "-") chip=\(field("Chip") ?? "-") " +
              "cores=\(field("Total Number of Cores") ?? "-") memory=\(field("Memory") ?? "-")")
        #expect(d.hwModel == field("Model Identifier"))
        #expect(d.chipName == field("Chip"))
        #expect(field("Memory") == "\(d.memoryBytes >> 30) GB")
        #expect(field("Total Number of Cores")?.hasPrefix("\(d.performanceCores + d.efficiencyCores)") == true)
        #expect(d.osBuild == DeviceInfoFFI.sysctlString("kern.osversion"))
        #expect(d.bootTime < Date() && d.bootTime > Date(timeIntervalSinceNow: -400 * 86_400))
    }
}
