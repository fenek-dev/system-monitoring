import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Parse layer on a captured AGX registry dump (`Fixtures/W6b/gpu_clients.plist`, taken under a Metal load).
struct GPUClientsParseTests {
    @Test func creatorStrings() {
        #expect(GPUClientsParse.creator("pid 98391, Browser Helper")! == (98391, "Browser Helper"))
        #expect(GPUClientsParse.creator("pid 418, WindowServer")! == (418, "WindowServer"))
        #expect(GPUClientsParse.creator("pid 7, Foo, Inc. Helper")! == (7, "Foo, Inc. Helper"))   // first comma only
        #expect(GPUClientsParse.creator("pid 0, kernel_task")! == (0, "kernel_task"))
        #expect(GPUClientsParse.creator("pid 12")! == (12, ""))
        #expect(GPUClientsParse.creator("pid  55 ,  Spaced ")! == (55, "Spaced"))
        #expect(GPUClientsParse.creator("pid x, Bad") == nil)
        #expect(GPUClientsParse.creator("pid -3, Neg") == nil)
        #expect(GPUClientsParse.creator("process 1, X") == nil)
        #expect(GPUClientsParse.creator("") == nil)
    }

    @Test func gpuTimeSumsAppUsageAndSaturates() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_414_821_875 as UInt64)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 5 as UInt64)],
            ["API": "Metal"],
        ]
        #expect(GPUClientsParse.gpuTimeNs(usage) == 1_414_821_880)
        #expect(GPUClientsParse.gpuTimeNs([]) == 0)
        #expect(GPUClientsParse.gpuTimeNs(nil) == 0)
        #expect(GPUClientsParse.gpuTimeNs("junk") == 0)
        let huge: [[String: Any]] = [["accumulatedGPUTime": NSNumber(value: UInt64.max)], ["accumulatedGPUTime": NSNumber(value: 1)]]
        #expect(GPUClientsParse.gpuTimeNs(huge) == .max)
    }

    @Test func performanceStatistics() {
        let p = GPUClientsParse.performance(["Device Utilization %": 86, "In use system memory": 1_025_212_416])
        #expect(p.utilization == 86 && p.inUseSystemMemory == 1_025_212_416)
        #expect(GPUClientsParse.performance(["Device Utilization %": 140]).utilization == 100)
        #expect(GPUClientsParse.performance(nil).utilization == nil)
    }

    @Test func capturedDump() throws {
        let plist = try PropertyListSerialization.propertyList(from: W6bFixture.data("gpu_clients.plist"), format: nil)
        let dict = try #require(plist as? [String: Any])
        let raw = try #require(dict["clients"] as? [[String: Any]])
        let clients = raw.compactMap {
            GPUClientsParse.client(id: ($0["id"] as? NSNumber)?.uint64Value ?? 0,
                                   creator: $0["IOUserClientCreator"], appUsage: $0["AppUsage"])
        }
        #expect(clients.count == raw.count)                  // every AGX client has a parseable creator
        #expect(Set(clients.map(\.clientID)).count == clients.count)
        #expect(clients.contains { $0.creatorName == "WindowServer" && $0.gpuTimeNs > 0 })
        #expect(clients.filter { $0.creatorName == "WindowServer" }.count == 2)   // one pid, several clients
        let busiest = try #require(clients.max { $0.gpuTimeNs < $1.gpuTimeNs })
        #expect(busiest.gpuTimeNs > 1_000_000_000)
        let perf = GPUClientsParse.performance(dict["PerformanceStatistics"])
        #expect((perf.utilization ?? 0) >= 80)                // captured under the Metal load
        #expect((perf.inUseSystemMemory ?? 0) > 0)
    }
}
