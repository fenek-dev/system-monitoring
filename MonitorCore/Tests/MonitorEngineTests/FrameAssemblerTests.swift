import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

@Suite struct FrameAssemblerTests {
    static let a = appID("a"), b = appID("b")

    /// pid 10 = app a (+ helper 11 responsible to 10), pid 20 = app b; 418/419 root in coalition 7 (leader 418),
    /// 500 root alone in coalition 8.
    static func tick(_ n: UInt64, v6: Bool = true, soc: SoCPowerReading? = SoCPowerReading(cpuWatts: 4, gpuWatts: 2),
                     flows: [FlowCounter] = [], health: [SensorID: SensorStatus] = [:]) -> RawTick {
        let t = n * sec
        let e: (UInt64) -> UInt64? = { v6 ? $0 : nil }
        let procs = [
            own(10, cpuNs: n * sec / 2, energyNJ: e(n * sec)),                      // 50 %, 1 W
            own(11, cpuNs: n * sec / 4, energyNJ: e(n * sec / 4), responsible: 10), // 25 %, 0.25 W
            own(20, cpuNs: n * sec / 10, energyNJ: e(n * sec / 10)),                // 10 %, 0.1 W
            foreign(418, comm: "WindowServer"), foreign(419, comm: "MTLCompilerService"), foreign(500, comm: "mds_stores"),
        ]
        let coal = CoalitionsReading(coalitions: [
            CoalitionUsage(id: 7, leaderPID: 418, memberPIDs: [418, 419], cpuTimeNs: n * sec * 3 / 5, energyNJ: n * sec / 2),
            CoalitionUsage(id: 8, leaderPID: 500, memberPIDs: [500], cpuTimeNs: n * sec / 5, energyNJ: n * sec / 5),
            CoalitionUsage(id: 9, leaderPID: 10, memberPIDs: [10, 11, 20], cpuTimeNs: n * sec, energyNJ: n * sec),
        ])
        let gpu = GPUClientsReading(clients: [GPUClientCounter(clientID: 1, pid: 20, creatorName: "p20", gpuTimeNs: n * sec / 5),
                                              GPUClientCounter(clientID: 2, pid: 777, creatorName: "gone", gpuTimeNs: n * sec / 10)])
        return RawTick(wallTime: Date(timeIntervalSince1970: Double(n)), uptimeNs: t, mode: .interactive,
                       processes: .fresh(ProcessTableReading(processes: procs), capturedNs: t),
                       coalitions: .fresh(coal, capturedNs: t),
                       soc: soc.map { .fresh($0, capturedNs: t) } ?? .notRequested,
                       gpuClients: .fresh(gpu, capturedNs: t),
                       networkFlows: .fresh(NetworkFlowsReading(flows: flows), capturedNs: t),
                       health: health)
    }

    static func assembler(energy: any EnergyAttributor = RulingEnergyAttributor()) -> FrameAssembler {
        FrameAssembler(resolver: FixtureAppResolver([10: a, 20: b]), energy: energy, currentUID: testUID)
    }

    @Test func composesProcessesAppsAndCoalitionRows() throws {
        var fa = Self.assembler()
        let first = fa.assemble(Self.tick(1), inspectedApp: nil)
        #expect(first.interval == nil)                         // no rates on the first frame
        let f = fa.assemble(Self.tick(2), inspectedApp: nil)
        #expect(f.interval == .seconds(1))
        #expect(f.mode == .interactive)
        #expect(f.wallTime == Date(timeIntervalSince1970: 2))

        // coalition 7: two restricted → one synthetic row named after the leader; coalition 8: sole member filled
        let synthetic = try #require(f.processes.first { $0.id == .coalitionResidual(7) })
        #expect(synthetic.name == "WindowServer")
        #expect(abs(synthetic.cpuPercent! - 60) < 1e-9)
        #expect(abs(synthetic.energyWatts! - 0.5) < 1e-9)
        #expect(synthetic.energyEstimated)
        let mds = try #require(f.processes[pid: 500])
        #expect(mds.provenance == .coalition)
        #expect(abs(mds.cpuPercent! - 20) < 1e-9)
        #expect(abs(mds.energyWatts! - 0.2) < 1e-9)
        #expect(f.processes[pid: 418]?.provenance == .restricted)
        #expect(f.processes[pid: 418]?.coalitionLeaderName == "WindowServer")
        // all-visible coalition 9 (1 W measured by coalition vs 1.35 W v6): untouched
        #expect(f.processes[pid: 10]?.energyWatts == 1)
        #expect(f.processes[pid: 10]?.energyEstimated == false)

        let appA = try #require(f.apps.first { $0.identity.key == Self.a.key })
        #expect(appA.processIDs.count == 2)
        #expect(appA.cpuPercent == 75)
        #expect(appA.energyWatts == 1.25)
        #expect(!appA.energyEstimated)
        #expect(f.apps.map(\.cpuPercent) == f.apps.map(\.cpuPercent).sorted { ($0 ?? -1) > ($1 ?? -1) })
        // unattributed AGX (creator 777 gone) → System
        let system = try #require(f.apps.first { $0.identity.key == .system })
        #expect(abs(system.gpuPercent! - 10) < 1e-9)
        #expect(f.apps.first { $0.identity.key == Self.b.key }?.gpuPercent == 20)
    }

    @Test func energyEstimatedPropagatesToAppsInFallbackMode() throws {
        var fa = Self.assembler()
        _ = fa.assemble(Self.tick(1, v6: false), inspectedApp: nil)
        let f = fa.assemble(Self.tick(2, v6: false), inspectedApp: nil)
        let appA = try #require(f.apps.first { $0.identity.key == Self.a.key })
        #expect(appA.energyEstimated)
        #expect(appA.energyWatts != nil)
        let total = f.processes.compactMap(\.energyWatts).reduce(0, +)
        #expect(total <= 6 + 1e-9)                              // never above IOReport CPU + GPU
        // coalition residual skipped in fallback mode: the synthetic row gets a SoC share, not 0.5 W coalition energy
        let synthetic = try #require(f.processes.first { $0.id == .coalitionResidual(7) })
        #expect(abs(synthetic.energyWatts! - 4 * 60.0 / 165) < 1e-9)
    }

    @Test func sessionTotalsAccumulate() throws {
        var fa = Self.assembler()
        for n: UInt64 in 1...4 { _ = fa.assemble(Self.tick(n), inspectedApp: nil) }
        let f = fa.assemble(Self.tick(5), inspectedApp: nil)
        let appA = try #require(f.apps.first { $0.identity.key == Self.a.key })
        #expect(appA.cpuTimeNs == 4 * 3 * sec / 4)             // 0.75 s CPU per tick after the first
        let b = try #require(f.apps.first { $0.identity.key == Self.b.key })
        #expect(b.gpuTimeNs == 4 * sec / 5)
        let windowServerApp = try #require(f.apps.first { $0.processIDs.contains { $0.pid == 418 } })
        #expect((windowServerApp.cpuTimeNs ?? 0) >= 4 * sec * 3 / 5 - 10)  // synthetic row CPU counted in session
    }

    @Test func cachedCoalitionReadingAddsNoSessionCPUForResidualRows() throws {
        var fa = Self.assembler()
        _ = fa.assemble(Self.tick(1), inspectedApp: nil)
        let f2 = fa.assemble(Self.tick(2), inspectedApp: nil)
        var t3 = Self.tick(3)
        t3.coalitions = .cached(Self.tick(2).coalitions.value!, capturedNs: 2 * sec)   // coalition sensor not due
        let f3 = fa.assemble(t3, inspectedApp: nil)
        let sys2 = try #require(f2.apps.first { $0.identity.key == .system })
        let sys3 = try #require(f3.apps.first { $0.identity.key == .system })
        #expect(sys2.cpuTimeNs == 4 * sec / 5)                  // synthetic 0.6 s + filled mds 0.2 s
        #expect(sys3.cpuTimeNs == sys2.cpuTimeNs)               // cached: rates reused, session unchanged
        #expect(abs(f3.processes.first { $0.id == .coalitionResidual(7) }!.cpuPercent! - 60) < 1e-9)
        #expect(abs(f3.processes[pid: 500]!.cpuPercent! - 20) < 1e-9)
    }

    @Test func sensorHealthAndDevice() {
        var fa = Self.assembler()
        let f = fa.assemble(Self.tick(1, health: [.smc: .unavailable("no SMC")]), inspectedApp: nil)
        #expect(f.sensorHealth[.smc] == .unavailable("no SMC"))
        #expect(f.device == .placeholder)
        var t = Self.tick(2)
        t.device = .cached(DeviceInfo(modelName: "MacBook Pro"), capturedNs: 1)
        #expect(fa.assemble(t, inspectedApp: nil).device.modelName == "MacBook Pro")
        #expect(fa.assemble(Self.tick(3), inspectedApp: nil).device.modelName == "MacBook Pro")   // kept
    }

    @Test func connectionsOnlyForInspectedApp() throws {
        var fa = Self.assembler()
        let flowsAt: (UInt64) -> [FlowCounter] = { n in [
            FlowCounter(flowID: 1, process: ProcessID(pid: 11, startTimeUs: 0), proto: .tcp, rxBytes: n * 1_000, txBytes: n * 10,
                        localPort: 5000, remoteAddress: "1.2.3.4", remotePort: 443, tcpState: "Established"),
            FlowCounter(flowID: 2, process: ProcessID(pid: 20, startTimeUs: 1), proto: .udp, rxBytes: n, txBytes: n),
        ] }
        _ = fa.assemble(Self.tick(1, flows: flowsAt(1)), inspectedApp: Self.a.key)
        let f = fa.assemble(Self.tick(2, flows: flowsAt(2)), inspectedApp: Self.a.key)
        #expect(f.connections.count == 1)
        let c = try #require(f.connections.first)
        #expect(c.id == 1 && c.app == Self.a.key && c.process.pid == 11)
        #expect(c.rxBps == 1_000 && c.txBps == 10)
        #expect(c.rxTotal == 2_000 && c.remoteAddress == "1.2.3.4" && c.remotePort == 443)
        #expect(fa.assemble(Self.tick(3, flows: flowsAt(3)), inspectedApp: nil).connections.isEmpty)
    }

    @Test func resetDropsRatesAndInterval() {
        var fa = Self.assembler()
        _ = fa.assemble(Self.tick(1), inspectedApp: nil)
        _ = fa.assemble(Self.tick(2), inspectedApp: nil)
        fa.reset()
        let f = fa.assemble(Self.tick(3), inspectedApp: nil)
        #expect(f.interval == nil)
        #expect(f.processes[pid: 10]?.cpuPercent == nil)
        #expect(!f.processes.contains { $0.id.isSynthetic })
    }

    @Test func missingProcessTableStillAssemblesSystem() {
        var fa = Self.assembler()
        let f = fa.assemble(RawTick(uptimeNs: sec, health: [.processes: .unavailable("x")]), inspectedApp: nil)
        #expect(f.processes.isEmpty && f.apps.isEmpty)
        #expect(f.sensorHealth[.processes] == .unavailable("x"))
    }

    // MARK: perf (advisory ≤ 3 ms)

    @Test func assemble920() {
        let (t1, t2) = Self.bigTicks()
        var times: [Double] = []
        for _ in 0..<100 {
            var fa = FrameAssembler(resolver: FixtureAppResolver([:]), currentUID: testUID)
            _ = fa.assemble(t1, inspectedApp: nil)
            let start = DispatchTime.now().uptimeNanoseconds
            let f = fa.assemble(t2, inspectedApp: nil)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            #expect(f.processes.count >= 920)
        }
        let mean = times.reduce(0, +) / Double(times.count)
        print("PERF assemble920 mean \(String(format: "%.3f", mean)) ms over 100 runs (advisory ≤ 3 ms)")
    }

    /// 920 pids (330 restricted), 770 coalitions.
    static func bigTicks() -> (RawTick, RawTick) {
        func make(_ n: UInt64) -> RawTick {
            var procs: [RawProcess] = []
            var coalitions: [CoalitionUsage] = []
            for c in 0..<770 { coalitions.append(CoalitionUsage(id: UInt64(c + 1), leaderPID: Int32(c + 1), memberPIDs: [],
                                                                 cpuTimeNs: n * UInt64(c + 1) * 1_000_000, energyNJ: n * 1_000)) }
            for i in 0..<920 {
                let pid = Int32(i + 1)
                let cid = i % 770
                coalitions[cid].memberPIDs.append(pid)
                if i < 330 {
                    procs.append(foreign(pid))
                } else {
                    procs.append(own(pid, cpuNs: n * UInt64(i) * 100_000, energyNJ: n * 1_000, diskR: n * 10, diskW: n * 10,
                                     responsible: Int32(331 + (i % 50))))
                }
            }
            let t = n * sec
            return RawTick(uptimeNs: t, processes: .fresh(ProcessTableReading(processes: procs), capturedNs: t),
                           coalitions: .fresh(CoalitionsReading(coalitions: coalitions), capturedNs: t),
                           soc: .fresh(SoCPowerReading(cpuWatts: 5, gpuWatts: 1), capturedNs: t))
        }
        return (make(1), make(2))
    }
}
