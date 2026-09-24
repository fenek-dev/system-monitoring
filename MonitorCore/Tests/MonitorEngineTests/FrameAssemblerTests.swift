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
            // all visible: coalition meter ~1 % above Σ rusage (85 %) — below the ICR-13 "Exited processes" threshold
            CoalitionUsage(id: 9, leaderPID: 10, memberPIDs: [10, 11, 20], cpuTimeNs: n * sec * 86 / 100, energyNJ: n * sec),
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
        #expect(!f.processes.contains { $0.id == .exitedResidual(9) })   // 86 vs 85 %: meter noise, no Exited row
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
        // ICR-8: v6 0.1 W + IOReport GPU 2 W × 20 % share → 0.5 W, estimated (GPU term > 10 %)
        let p20 = try #require(f.processes[pid: 20])
        #expect(abs(p20.energyWatts! - 0.5) < 1e-9)
        #expect(p20.energyEstimated)
    }

    @Test func spawnAndExitLoadIsRecoveredThroughTheCoalition() throws {
        // A build: pid 10 (50 %) keeps spawning children that start and exit between ticks (100 % of a core in total,
        // never in any process table). Only the all-visible coalition 4 sees their CPU. 2 cores; the host sees 150 %.
        func tick(_ n: UInt64) -> RawTick {
            let core = CoreTicks(user: n * 75, system: 0, idle: n * 25)              // 75 % busy per core × 2
            return RawTick(wallTime: Date(timeIntervalSince1970: Double(n)), uptimeNs: n * sec, mode: .interactive,
                           processes: .fresh(ProcessTableReading(processes: [own(10, cpuNs: n * sec / 2, energyNJ: n * sec)]),
                                             capturedNs: n * sec),
                           coalitions: .fresh(CoalitionsReading(coalitions: [
                               CoalitionUsage(id: 4, leaderPID: 10, memberPIDs: [10], cpuTimeNs: n * sec * 3 / 2,
                                              energyNJ: n * sec * 3),
                           ]), capturedNs: n * sec),
                           hostCPU: .fresh(HostCPUReading(cores: [core, core], coreKinds: [.performance, .performance]),
                                           capturedNs: n * sec))
        }
        var fa = Self.assembler()
        _ = fa.assemble(tick(1), inspectedApp: nil)
        let f = fa.assemble(tick(2), inspectedApp: nil)
        let system = try #require(f.cpu.usage) * 100 * 2
        let appSum = f.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
        #expect(abs(system - 150) < 1e-6)
        #expect(abs(appSum - system) < 1e-6)                                     // was 50 of 150 before ICR-13
        let exited = try #require(f.processes.first { $0.id == .exitedResidual(4) })
        #expect(abs(exited.cpuPercent! - 100) < 1e-9)
        #expect(exited.app == Self.a.key)                                        // counted in the leader's app
        #expect(abs(exited.energyWatts! - 2) < 1e-9 && exited.energyEstimated)   // 3 W coalition − 1 W v6
        let app = try #require(f.apps.first { $0.identity.key == Self.a.key })
        #expect(app.cpuPercent == 150)
        // The exited share is exposed separately (UI: "Exited processes", not hidden processes).
        #expect(app.exitedResidual.map { abs(($0[.cpu] ?? 0) - 100) < 1e-9 } == true)
        #expect(app.exitedResidual.map { abs(($0[.energy] ?? 0) - 2) < 1e-9 } == true)
        #expect(app.coalitionResidual.map { abs(($0[.cpu] ?? 0) - 100) < 1e-9 } == true)
    }

    @Test func unlistedNewbornChildIsNotCountedTwice() throws {
        // pid 30 was born mid-interval (child of 10) and is in the process table, but the coalition reading doesn't
        // list it (born after it was built). Its CPU is in the coalition's Δ AND its own newborn row: it must be
        // subtracted from the residual (parent's coalition), so Σ apps ≤ system and no Exited row carries it.
        let w0 = 1_790_000_000.0
        func tick(_ n: UInt64, child: Bool) -> RawTick {
            let core = CoreTicks(user: n * 50 + (child ? 40 : 0), system: 0, idle: n * 50 - (child ? 40 : 0))
            var ps = [own(10, cpuNs: n * sec / 2, energyNJ: n * sec)]
            var coalCPU = n * sec / 2
            if child {
                var c = own(30, start: UInt64((w0 + Double(n) - 0.5) * 1e6), cpuNs: 4 * sec / 10, energyNJ: sec / 10)
                c.ppid = 10
                ps.append(c)
                coalCPU += 4 * sec / 10
            }
            return RawTick(wallTime: Date(timeIntervalSince1970: w0 + Double(n)), uptimeNs: n * sec, mode: .interactive,
                           processes: .fresh(ProcessTableReading(processes: ps), capturedNs: n * sec),
                           coalitions: .fresh(CoalitionsReading(coalitions: [
                               CoalitionUsage(id: 4, leaderPID: 10, memberPIDs: [10], cpuTimeNs: coalCPU, energyNJ: n * sec),
                           ]), capturedNs: n * sec),
                           hostCPU: .fresh(HostCPUReading(cores: [core], coreKinds: [.performance]), capturedNs: n * sec))
        }
        var fa = Self.assembler()
        _ = fa.assemble(tick(1, child: false), inspectedApp: nil)
        let f = fa.assemble(tick(2, child: true), inspectedApp: nil)
        let system = try #require(f.cpu.usage) * 100
        let appSum = f.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
        #expect(f.processes[pid: 30]?.cpuPercent == 40)                         // newborn row
        #expect(f.processes[pid: 30]?.coalitionID == 4)                         // parent's coalition
        #expect(!f.processes.contains { $0.id == .exitedResidual(4) })         // nothing left over
        #expect(appSum <= system + 1e-6)
        #expect(abs(appSum - 90) < 1e-6)
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
        #expect(windowServerApp.cpuTimeNs == 4 * 4 * sec / 5)     // synthetic 0.6 s + filled mds 0.2 s per tick
        #expect(windowServerApp.gpuTimeNs == 4 * sec / 10)        // unattributed AGX (creator gone) → System
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

    private static func flows(_ n: UInt64) -> [FlowCounter] {
        [FlowCounter(flowID: 1, process: ProcessID(pid: 11, startTimeUs: 0), proto: .tcp, rxBytes: n * 1_000, txBytes: n * 10),
         FlowCounter(flowID: 2, process: ProcessID(pid: 20, startTimeUs: 1), proto: .udp, rxBytes: n * 7, txBytes: n)]
    }

    @Test func switchingInspectedAppSwitchesConnections() {
        var fa = Self.assembler()
        _ = fa.assemble(Self.tick(1, flows: Self.flows(1)), inspectedApp: Self.a.key)
        let a = fa.assemble(Self.tick(2, flows: Self.flows(2)), inspectedApp: Self.a.key)
        #expect(a.connections.map(\.id) == [1])
        let b = fa.assemble(Self.tick(3, flows: Self.flows(3)), inspectedApp: Self.b.key)
        #expect(b.connections.map(\.id) == [2])
        #expect(b.connections.first?.app == Self.b.key)
        #expect(b.connections.first?.rxBps == nil)               // B's flow has no baseline yet
        let b2 = fa.assemble(Self.tick(4, flows: Self.flows(4)), inspectedApp: Self.b.key)
        #expect(b2.connections.first?.rxBps == 7)
    }

    @Test func cachedFlowsReadingReusesPreviousRate() {
        var fa = Self.assembler()
        _ = fa.assemble(Self.tick(1, flows: Self.flows(1)), inspectedApp: Self.a.key)
        _ = fa.assemble(Self.tick(2, flows: Self.flows(2)), inspectedApp: Self.a.key)
        var t3 = Self.tick(3)
        t3.networkFlows = .cached(NetworkFlowsReading(flows: Self.flows(2)), capturedNs: 2 * sec)
        let f = fa.assemble(t3, inspectedApp: Self.a.key)
        #expect(f.connections.first?.rxBps == 1_000)
        #expect(f.processes[pid: 11]?.netRxBps == 1_000)
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
            #expect(f.processes.contains { $0.id.isSynthetic })
        }
        let mean = times.reduce(0, +) / Double(times.count)
        print("PERF assemble920 mean \(String(format: "%.3f", mean)) ms over 100 runs (advisory ≤ 3 ms)")
    }

    /// 920 pids (330 restricted), 770 coalitions: 80 with two restricted members (synthetic rows), 170 with one
    /// (fills), ~85 visible members mixed into restricted coalitions; 60 AGX clients; 400 NStat flows.
    static func bigTicks() -> (RawTick, RawTick) {
        func make(_ n: UInt64) -> RawTick {
            var procs: [RawProcess] = []
            var coalitions: [CoalitionUsage] = []
            for c in 0..<770 { coalitions.append(CoalitionUsage(id: UInt64(c + 1), leaderPID: nil, memberPIDs: [],
                                                                 cpuTimeNs: n * UInt64(c + 1) * 10_000_000,
                                                                 energyNJ: n * 100_000_000, diskReadBytes: n * 4_096,
                                                                 diskWriteBytes: n * 4_096)) }
            for i in 0..<920 {
                let pid = Int32(i + 1)
                let cid: Int
                if i < 330 {
                    cid = i % 250                                      // cids 0…79 get two restricted members
                    procs.append(foreign(pid))
                } else {
                    cid = i % 7 == 0 ? i % 250 : 250 + (i - 330) % 520
                    procs.append(own(pid, cpuNs: n * UInt64(i) * 100_000, energyNJ: n * 1_000, diskR: n * 10, diskW: n * 10,
                                     responsible: Int32(331 + (i % 50))))
                }
                coalitions[cid].memberPIDs.append(pid)
                if coalitions[cid].leaderPID == nil { coalitions[cid].leaderPID = pid }
            }
            // All-visible coalitions (250…769): the coalition meter ≈ Σ members (+1 % noise), as on a real Mac — else
            // ~500 of them would carry an ICR-13 "Exited processes" residual and the bench would measure those rows.
            for cid in 250..<770 {
                let members = coalitions[cid].memberPIDs.map { UInt64($0 - 1) }            // pid = i + 1
                coalitions[cid].cpuTimeNs = members.reduce(0) { $0 + n * $1 * 100_000 } * 101 / 100
            }
            let clients = (0..<60).map { k in
                GPUClientCounter(clientID: UInt64(k), pid: Int32(331 + k * 9), creatorName: "p\(331 + k * 9)",
                                 gpuTimeNs: n * UInt64(k) * 1_000_000)
            }
            let flows: [FlowCounter] = (0..<400).map { (k: Int) -> FlowCounter in
                let start: UInt64 = k % 2 == 0 ? 1 : 0
                let kk = UInt64(k)
                return FlowCounter(flowID: kk, process: ProcessID(pid: Int32(331 + k), startTimeUs: start),
                                   proto: .tcp, rxBytes: n * kk * 100, txBytes: n * kk * 10)
            }
            let t = n * sec
            return RawTick(uptimeNs: t, processes: .fresh(ProcessTableReading(processes: procs), capturedNs: t),
                           coalitions: .fresh(CoalitionsReading(coalitions: coalitions), capturedNs: t),
                           soc: .fresh(SoCPowerReading(cpuWatts: 5, gpuWatts: 1), capturedNs: t),
                           gpuClients: .fresh(GPUClientsReading(clients: clients), capturedNs: t),
                           networkFlows: .fresh(NetworkFlowsReading(flows: flows), capturedNs: t))
        }
        return (make(1), make(2))
    }
}
