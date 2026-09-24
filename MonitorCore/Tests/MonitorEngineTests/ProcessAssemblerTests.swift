import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

@Suite struct ProcessAssemblerTests {
    let resolver = FixtureAppResolver([10: appID("a"), 20: appID("b")])

    private func run(_ pa: inout ProcessAssembler, _ ps: [RawProcess], at t: UInt64,
                     gpu: SensorResult<GPUClientsReading> = .notRequested,
                     flows: SensorResult<NetworkFlowsReading> = .notRequested,
                     rootMemory: SensorResult<RootMemoryReading> = .notRequested,
                     assertions: SensorResult<SleepAssertionsReading> = .notRequested,
                     coalitionOf: [Int32: UInt64] = [:]) -> ProcessAssembly {
        pa.assemble(ProcessInputs(processes: table(ps, at: t), gpuClients: gpu, flows: flows, rootMemory: rootMemory,
                                  assertions: assertions, coalitionOf: coalitionOf, uptimeNs: t),
                    resolver: resolver)
    }

    // MARK: rusage v6

    @Test func firstSightHasNoRatesThenDeltas() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        let a0 = run(&pa, [own(10, cpuNs: 0, energyNJ: 0, diskR: 0, diskW: 0)], at: 1 * sec)
        let p0 = try #require(a0.samples[pid: 10])
        #expect(p0.cpuPercent == nil && p0.energyWatts == nil && p0.diskReadBps == nil)
        #expect(a0.interval == nil)

        let a1 = run(&pa, [own(10, cpuNs: sec / 2, energyNJ: 3 * sec, footprint: 5_000, diskR: 4_000, diskW: 2_000)],
                     at: 3 * sec)
        let p = try #require(a1.samples[pid: 10])
        #expect(a1.interval == 2)
        #expect(p.cpuPercent == 25)                          // 0.5 s CPU over 2 s
        #expect(p.cpuTimeNs == sec / 2)
        #expect(p.energyWatts == 1.5)                        // 3 J over 2 s
        #expect(p.diskReadBps == 2_000 && p.diskWriteBps == 1_000)
        #expect(p.diskReadTotal == 4_000 && p.diskWriteTotal == 2_000)
        #expect(p.memory == 5_000 && p.memorySource == .footprint)
        #expect(p.provenance == .measured)
        #expect(p.isCurrentUser)
        #expect(p.app == AppKey(kind: .app, id: "a"))
        #expect(p.threads == 1)
        #expect(a1.deltas[p.id]?.cpuNs == sec / 2)
        #expect(a1.identities[p.app]?.displayName == "a")
        #expect(a1.identityByPID[10]?.displayName == "a")
    }

    @Test func processBornWithinTheIntervalContributes() throws {
        // Spawn-heavy loads (builds): a process started after the previous capture accrued all its counters inside
        // this interval → counter / interval. One seen for the first time but older than that stays nil.
        let w0 = Date(timeIntervalSince1970: 1_790_000_000)
        var pa = ProcessAssembler(currentUID: testUID, sessionStartUs: UInt64((w0.timeIntervalSince1970 - 10) * 1e6))
        func inputs(_ ps: [RawProcess], at t: UInt64, wall: Date) -> ProcessInputs {
            ProcessInputs(processes: table(ps, at: t), uptimeNs: t, wallTime: wall)
        }
        let us: (Double) -> UInt64 = { UInt64((w0.timeIntervalSince1970 + $0) * 1e6) }
        _ = pa.assemble(inputs([own(10, cpuNs: 0)], at: sec, wall: w0), resolver: resolver)
        let a = pa.assemble(inputs([
            own(10, cpuNs: sec),
            own(20, start: us(1), cpuNs: sec / 2, energyNJ: sec, diskR: 0, diskW: 4_000),     // born mid-interval
            own(30, start: us(-100), cpuNs: 7 * sec),                                          // old, first seen
        ], at: 3 * sec, wall: w0.addingTimeInterval(2)), resolver: resolver)
        let born = try #require(a.samples[pid: 20])
        #expect(born.cpuPercent == 25)                       // 0.5 s over the 2 s interval
        #expect(born.energyWatts == 0.5)
        #expect(born.diskWriteBps == 2_000 && born.diskReadBps == 0)
        #expect(a.deltas[born.id]?.cpuNs == sec / 2)         // session totals and coalition Δvisible see it
        #expect(a.samples[pid: 30]?.cpuPercent == nil)
        #expect(a.samples[pid: 10]?.cpuPercent == 50)

        // Next tick it's an ordinary delta.
        let b = pa.assemble(inputs([own(20, start: us(1), cpuNs: sec, energyNJ: sec, diskR: 0, diskW: 4_000)],
                                   at: 4 * sec, wall: w0.addingTimeInterval(3)), resolver: resolver)
        #expect(b.samples[pid: 20]?.cpuPercent == 50)

        // After a reset (wake) the first frame has no rates, newborn or not.
        pa.reset()
        let c = pa.assemble(inputs([own(40, start: us(3.5), cpuNs: sec)], at: 5 * sec, wall: w0.addingTimeInterval(4)),
                            resolver: resolver)
        #expect(c.samples[pid: 40]?.cpuPercent == nil)
        // No wall time → no fill-in (legacy inputs).
        var legacy = ProcessAssembler(currentUID: testUID)
        _ = run(&legacy, [own(10, cpuNs: 0)], at: sec)
        #expect(run(&legacy, [own(20, start: us(1), cpuNs: sec)], at: 2 * sec).samples[pid: 20]?.cpuPercent == nil)
    }

    @Test func sessionNewbornCountsFullCountersOnceEvenAfterWake() throws {
        // Session start = Telltale's start. A process started exactly then, first seen at the first tick (no rates
        // yet): its whole CPU/disk goes to the session once — not again at the first sight after a wake reset.
        let startUs: UInt64 = 1_790_000_000_000_000
        var pa = ProcessAssembler(currentUID: testUID, sessionStartUs: startUs)
        let w0 = Date(timeIntervalSince1970: 1_790_000_002)
        func run(_ cpuNs: UInt64, at t: UInt64) -> ProcessAssembly {
            pa.assemble(ProcessInputs(processes: table([own(10, start: startUs, cpuNs: cpuNs, diskR: 0, diskW: cpuNs / 1_000)],
                                                       at: t),
                                      uptimeNs: t, wallTime: w0.addingTimeInterval(Double(t / sec))), resolver: resolver)
        }
        let first = run(2 * sec, at: sec)
        #expect(first.samples[pid: 10]?.cpuPercent == nil)                    // no rate on the first frame
        #expect(first.deltas[ProcessID(pid: 10, startTimeUs: startUs)]?.cpuNs == 2 * sec)
        #expect(first.deltas[ProcessID(pid: 10, startTimeUs: startUs)]?.diskW == 2 * sec / 1_000)
        pa.reset()                                                             // wake: baselines gone
        let afterWake = run(3 * sec, at: 2 * sec)
        let d = afterWake.deltas[ProcessID(pid: 10, startTimeUs: startUs)]
        #expect((d?.cpuNs ?? 0) == 0)                                          // CPU not counted again (reset gap)
        #expect(d?.diskW == sec / 1_000)                                       // disk: only its session growth
    }

    @Test func counterGoingBackwardsOnARecentProcessIsNotOvercounted() {
        // A newborn's counter regressing later is a rebaseline (nil), never "first sight" again.
        let w0 = Date(timeIntervalSince1970: 1_790_000_000)
        var pa = ProcessAssembler(currentUID: testUID, sessionStartUs: UInt64((w0.timeIntervalSince1970 - 10) * 1e6))
        // Born at tick 2's capture: at tick 3 startTimeUs ≥ bornAfterUs still holds, so only the explicit-first-sight
        // rule keeps the regressed counter from being counted as a newborn again.
        let born = UInt64((w0.timeIntervalSince1970 + 2) * 1e6)
        func run(_ ps: [RawProcess], _ n: Double) -> ProcessAssembly {
            pa.assemble(ProcessInputs(processes: table(ps, at: UInt64(n) * sec), uptimeNs: UInt64(n) * sec,
                                      wallTime: w0.addingTimeInterval(n)), resolver: resolver)
        }
        _ = run([own(10, cpuNs: 0)], 1)
        let a = run([own(10, cpuNs: 0), own(20, start: born, cpuNs: sec / 2, diskR: 0, diskW: 8_000)], 2)
        #expect(a.samples[pid: 20]?.cpuPercent == 50)                         // newborn: 0.5 s over 1 s
        let b = run([own(10, cpuNs: 0), own(20, start: born, cpuNs: sec / 10, diskR: 0, diskW: 100)], 3)
        #expect(b.samples[pid: 20]?.cpuPercent == nil)                        // regressed: rebaseline, not 10 %
        #expect(b.samples[pid: 20]?.diskWriteBps == nil)
        #expect(b.deltas[ProcessID(pid: 20, startTimeUs: born)] == nil)
    }

    @Test func processMissingFromMembershipInheritsItsParentsCoalition() {
        // A build child born after (or exited before) the coalition read: parent's coalition, else responsible's.
        let map: [Int32: UInt64] = [10: 7, 20: 9]
        var child = own(30, cpuNs: sec)
        child.ppid = 10
        #expect(ProcessAssembler.coalition(of: child, in: map) == 7)
        child.ppid = 1                                                     // launchd child: responsible's coalition
        child.responsiblePID = 20
        #expect(ProcessAssembler.coalition(of: child, in: map) == 9)
        child.responsiblePID = nil
        #expect(ProcessAssembler.coalition(of: child, in: map) == nil)
        #expect(ProcessAssembler.coalition(of: own(10), in: map) == 7)     // listed members use their own
        #expect(ProcessAssembler.coalition(of: own(40), in: map, sticky: [40: 9]) == 9)   // just exited: sticky
        // Grandchild: its parent (50) is unlisted too, the grandparent (10) is listed → walk ancestors.
        var parent = own(50)
        parent.ppid = 10
        var grandchild = own(51)
        grandchild.ppid = 50
        grandchild.responsiblePID = 20                                       // ancestors win over responsible
        #expect(ProcessAssembler.coalition(of: grandchild, in: map, rawByPID: [50: parent]) == 7)
        #expect(ProcessAssembler.coalition(of: grandchild, in: map) == 9)    // ancestry unknown → responsible
    }

    @Test func cachedReadingKeepsPreviousRates() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        _ = run(&pa, [own(10, cpuNs: 0)], at: sec)
        _ = run(&pa, [own(10, cpuNs: sec)], at: 2 * sec)
        let cached = pa.assemble(ProcessInputs(processes: .cached(ProcessTableReading(processes: [own(10, cpuNs: sec)]),
                                                                 capturedNs: 2 * sec), uptimeNs: 3 * sec),
                                 resolver: resolver)
        #expect(cached.samples[pid: 10]?.cpuPercent == 100)
    }

    @Test func pidReuseIsANewProcess() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        _ = run(&pa, [own(10, start: 1, cpuNs: 5 * sec)], at: sec)
        let a = run(&pa, [own(10, start: 2, cpuNs: 6 * sec)], at: 2 * sec)   // same pid, new start time
        #expect(a.samples[pid: 10]?.cpuPercent == nil)
        #expect(a.samples[pid: 10]?.id == ProcessID(pid: 10, startTimeUs: 2))
    }

    @Test func counterDecreaseIsNilNotWrap() {
        var pa = ProcessAssembler(currentUID: testUID)
        _ = run(&pa, [own(10, cpuNs: 5 * sec, energyNJ: 100)], at: sec)
        let a = run(&pa, [own(10, cpuNs: 1, energyNJ: 1)], at: 2 * sec)
        #expect(a.samples[pid: 10]?.cpuPercent == nil)
        #expect(a.samples[pid: 10]?.energyWatts == nil)
    }

    @Test func pruneKeepsCalculatorsBounded() {
        var pa = ProcessAssembler(currentUID: testUID)
        for i in 0..<50 { _ = run(&pa, [own(Int32(100 + i), cpuNs: 0)], at: UInt64(i + 1) * sec) }
        #expect(pa.trackedKeyCount <= 4)                     // cpu/energy/diskR/diskW of the one live pid, not 50 pids
    }

    // MARK: restricted

    @Test func restrictedRowHasNoCountersAndRSSWhenRootMemoryRan() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        let root = SensorResult<RootMemoryReading>.cached(RootMemoryReading(rssByPID: [418: 800_000]), capturedNs: 1 * sec)
        _ = run(&pa, [foreign(418, comm: "WindowServer")], at: sec)
        let a = run(&pa, [foreign(418, comm: "WindowServer")], at: 4 * sec, rootMemory: root, coalitionOf: [418: 7])
        let p = try #require(a.samples[pid: 418])
        #expect(p.provenance == .restricted)
        #expect(p.cpuPercent == nil && p.energyWatts == nil && p.diskReadBps == nil)
        #expect(p.name == "WindowServer")
        #expect(p.user == "root")
        #expect(!p.isCurrentUser)
        #expect(p.memory == 800_000)
        #expect(p.memorySource == .rss(ageNs: 3 * sec))
        #expect(p.coalitionID == 7)
        #expect(p.app == .system)                            // fixture resolver has no entry
    }

    @Test func restrictedWithoutRootMemoryHasNoMemory() {
        var pa = ProcessAssembler(currentUID: testUID)
        let a = run(&pa, [foreign(418)], at: sec)
        #expect(a.samples[pid: 418]?.memory == nil)
        #expect(a.samples[pid: 418]?.memorySource == nil)
    }

    // MARK: AGX

    private func gpu(_ clients: [GPUClientCounter], at t: UInt64) -> SensorResult<GPUClientsReading> {
        .fresh(GPUClientsReading(clients: clients), capturedNs: t)
    }

    @Test func gpuClientsSummedPerPid() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        let ps = [own(10), own(20)]
        _ = run(&pa, ps, at: sec, gpu: gpu([GPUClientCounter(clientID: 1, pid: 10, creatorName: "a", gpuTimeNs: 0),
                                            GPUClientCounter(clientID: 2, pid: 10, creatorName: "a", gpuTimeNs: 0)], at: sec))
        let a = run(&pa, ps, at: 2 * sec,
                    gpu: gpu([GPUClientCounter(clientID: 1, pid: 10, creatorName: "a", gpuTimeNs: sec / 10),
                              GPUClientCounter(clientID: 2, pid: 10, creatorName: "a", gpuTimeNs: sec / 5)], at: 2 * sec))
        #expect(abs((a.samples[pid: 10]?.gpuPercent ?? -1) - 30) < 1e-9)
        #expect(a.samples[pid: 10]?.gpuTimeNs == 3 * sec / 10)
        #expect(a.samples[pid: 20]?.gpuPercent == 0)        // AGX lists every client: no client → 0 %
        #expect(a.deltas[a.samples[pid: 10]!.id]?.gpuNs == 3 * sec / 10)
    }

    @Test func gpuClientResetOrRecreateReadsZeroNotWrap() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        let ps = [own(10)]
        _ = run(&pa, ps, at: sec, gpu: gpu([GPUClientCounter(clientID: 1, pid: 10, creatorName: "a", gpuTimeNs: 5 * sec)], at: sec))
        let reset = run(&pa, ps, at: 2 * sec,
                        gpu: gpu([GPUClientCounter(clientID: 1, pid: 10, creatorName: "a", gpuTimeNs: 10)], at: 2 * sec))
        #expect(reset.samples[pid: 10]?.gpuPercent == 0)
        let recreated = run(&pa, ps, at: 3 * sec,
                            gpu: gpu([GPUClientCounter(clientID: 9, pid: 10, creatorName: "a", gpuTimeNs: 99 * sec)], at: 3 * sec))
        #expect(recreated.samples[pid: 10]?.gpuPercent == 0)
    }

    @Test func gpuOfExitedCreatorIsUnattributed() {
        var pa = ProcessAssembler(currentUID: testUID)
        let ps = [own(10)]
        _ = run(&pa, ps, at: sec, gpu: gpu([GPUClientCounter(clientID: 1, pid: 77, creatorName: "gone", gpuTimeNs: 0)], at: sec))
        let a = run(&pa, ps, at: 2 * sec,
                    gpu: gpu([GPUClientCounter(clientID: 1, pid: 77, creatorName: "gone", gpuTimeNs: sec / 2)], at: 2 * sec))
        #expect(a.unattributed.gpuPercent == 50)
        #expect(a.unattributedDelta.gpuNs == sec / 2)
    }

    @Test func gpuUnavailableIsNil() {
        var pa = ProcessAssembler(currentUID: testUID)
        _ = run(&pa, [own(10)], at: sec)
        let a = run(&pa, [own(10)], at: 2 * sec, gpu: .failed(.unavailable("no AGX"), last: nil, capturedNs: nil))
        #expect(a.samples[pid: 10]?.gpuPercent == nil)
    }

    // MARK: NStat

    private func flows(_ f: [FlowCounter], closed: [ProcessID: ByteCounts] = [:], unattributed: ByteCounts = ByteCounts(),
                       at t: UInt64) -> SensorResult<NetworkFlowsReading> {
        .fresh(NetworkFlowsReading(flows: f, closedBytes: closed, unattributedBytes: unattributed), capturedNs: t)
    }

    @Test func networkPerProcessIncludingClosedFlows() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        let id = ProcessID(pid: 10, startTimeUs: 1)
        let ps = [own(10)]
        _ = run(&pa, ps, at: sec, flows: flows([FlowCounter(flowID: 1, process: id, rxBytes: 1_000, txBytes: 100)], at: sec))
        // flow 1 closed (its bytes moved to closedBytes), flow 2 opened: cumulative stays monotonic
        let a = run(&pa, ps, at: 2 * sec,
                    flows: flows([FlowCounter(flowID: 2, process: id, rxBytes: 500, txBytes: 0)],
                                 closed: [id: ByteCounts(rx: 1_200, tx: 100)], at: 2 * sec))
        let p = try #require(a.samples[pid: 10])
        #expect(p.netRxBps == 700)
        #expect(p.netTxBps == 0)
        #expect(p.netRxTotal == 1_700)
        #expect(p.connectionCount == 1)
        #expect(a.deltas[id]?.rx == 700)
    }

    @Test func unknownStartTimeMatchesLivePid() {
        var pa = ProcessAssembler(currentUID: testUID)
        let loose = ProcessID(pid: 10, startTimeUs: 0)
        let ps = [own(10, start: 42)]
        _ = run(&pa, ps, at: sec, flows: flows([FlowCounter(flowID: 1, process: loose, rxBytes: 0, txBytes: 0)], at: sec))
        let a = run(&pa, ps, at: 2 * sec, flows: flows([FlowCounter(flowID: 1, process: loose, rxBytes: 300, txBytes: 30)], at: 2 * sec))
        #expect(a.samples[pid: 10]?.netRxBps == 300)
        #expect(a.samples[pid: 10]?.netTxBps == 30)
    }

    @Test func deadPidAndUnattributedBytesGoToSystem() {
        var pa = ProcessAssembler(currentUID: testUID)
        let dead = ProcessID(pid: 99, startTimeUs: 5)
        let ps = [own(10)]
        _ = run(&pa, ps, at: sec, flows: flows([FlowCounter(flowID: 1, process: dead, rxBytes: 0, txBytes: 0)],
                                               unattributed: ByteCounts(rx: 10, tx: 0), at: sec))
        let a = run(&pa, ps, at: 2 * sec, flows: flows([FlowCounter(flowID: 1, process: dead, rxBytes: 100, txBytes: 20)],
                                                       unattributed: ByteCounts(rx: 60, tx: 5), at: 2 * sec))
        #expect(a.unattributed.netRxBps == 150)
        #expect(a.unattributed.netTxBps == 25)
        #expect(a.unattributedDelta.rx == 150)
        #expect(a.samples[pid: 10]?.netRxBps == 0)
    }

    @Test func exitedProcessClosedBytesDoNotSpike() {
        var pa = ProcessAssembler(currentUID: testUID)
        let gone = ProcessID(pid: 30, startTimeUs: 1)
        _ = run(&pa, [own(10), own(30)], at: sec,
                flows: flows([FlowCounter(flowID: 1, process: gone, rxBytes: 5_000_000, txBytes: 0)], at: sec))
        // pid 30 exits; its lifetime bytes stay in closedBytes → no new bytes, so no rate anywhere
        let a = run(&pa, [own(10)], at: 2 * sec, flows: flows([], closed: [gone: ByteCounts(rx: 5_000_000, tx: 0)], at: 2 * sec))
        #expect((a.unattributed.netRxBps ?? 0) == 0)
    }

    @Test func networkUnavailableIsNil() {
        var pa = ProcessAssembler(currentUID: testUID)
        let a = run(&pa, [own(10)], at: sec)
        #expect(a.samples[pid: 10]?.netRxBps == nil)
        #expect(a.samples[pid: 10]?.connectionCount == nil)
    }

    @Test func loosePidDoesNotLeakIntoReusedPid() {
        var pa = ProcessAssembler(currentUID: testUID)
        let loose = ProcessID(pid: 10, startTimeUs: 0)
        _ = run(&pa, [own(10, start: 1)], at: sec, flows: flows([FlowCounter(flowID: 1, process: loose, rxBytes: 100)], at: sec))
        _ = run(&pa, [own(10, start: 1)], at: 2 * sec, flows: flows([FlowCounter(flowID: 1, process: loose, rxBytes: 200)], at: 2 * sec))
        // process exits, pid 10 reused by a new process; the old process's bytes stay keyed (10, 0) in closedBytes
        let a = run(&pa, [own(10, start: 9)], at: 3 * sec,
                    flows: flows([], closed: [loose: ByteCounts(rx: 5_000, tx: 0)], at: 3 * sec))
        #expect(a.samples[pid: 10]?.netRxTotal == nil)          // not inherited
        #expect(a.samples[pid: 10]?.netRxBps == 0)
        #expect(a.unattributed.netRxBps == 4_800)                 // the old process's last bytes → System
    }

    // MARK: cached readings never double count session deltas

    @Test func cachedReadingsYieldNoSessionDeltas() throws {
        var pa = ProcessAssembler(currentUID: testUID)
        let ps = [own(10, cpuNs: 0)]
        let id = ProcessID(pid: 10, startTimeUs: 1)
        func g(_ ns: UInt64) -> GPUClientsReading {
            GPUClientsReading(clients: [GPUClientCounter(clientID: 1, pid: 10, creatorName: "a", gpuTimeNs: ns),
                                        GPUClientCounter(clientID: 2, pid: 99, creatorName: "gone", gpuTimeNs: ns)])
        }
        func f(_ b: UInt64) -> NetworkFlowsReading {
            NetworkFlowsReading(flows: [FlowCounter(flowID: 1, process: id, rxBytes: b, txBytes: b)], unattributedBytes: ByteCounts(rx: b, tx: 0))
        }
        _ = run(&pa, ps, at: sec, gpu: .fresh(g(0), capturedNs: sec), flows: .fresh(f(0), capturedNs: sec))
        let fresh = run(&pa, [own(10, cpuNs: sec)], at: 2 * sec, gpu: .fresh(g(sec), capturedNs: 2 * sec),
                        flows: .fresh(f(1_000), capturedNs: 2 * sec))
        #expect(fresh.deltas[id] == ProcessDelta(cpuNs: sec, gpuNs: sec, rx: 1_000, tx: 1_000))
        #expect(fresh.unattributedDelta == ProcessDelta(gpuNs: sec, rx: 1_000))
        #expect(fresh.advanced)

        let cached = pa.assemble(ProcessInputs(
            processes: .cached(ProcessTableReading(processes: [own(10, cpuNs: sec)]), capturedNs: 2 * sec),
            gpuClients: .cached(g(sec), capturedNs: 2 * sec), flows: .cached(f(1_000), capturedNs: 2 * sec),
            uptimeNs: 3 * sec), resolver: resolver)
        #expect(!cached.advanced)
        #expect(cached.deltas.values.allSatisfy { $0 == ProcessDelta() })
        #expect(cached.unattributedDelta == ProcessDelta())
        // …while the displayed rates stay the previous ones
        let p = try #require(cached.samples[pid: 10])
        #expect(p.cpuPercent == 100 && p.gpuPercent == 100 && p.netRxBps == 1_000)
    }

    // MARK: misc

    @Test func sleepAssertions() {
        var pa = ProcessAssembler(currentUID: testUID)
        let a = run(&pa, [own(10), own(20)], at: sec,
                    assertions: .fresh(SleepAssertionsReading(byPID: [20: ["PreventUserIdleSystemSleep"]]), capturedNs: sec))
        #expect(a.samples[pid: 20]?.preventsSleep == true)
        #expect(a.samples[pid: 10]?.preventsSleep == false)
    }

    @Test func responsibleProcessDrivesIdentity() {
        var pa = ProcessAssembler(currentUID: testUID)
        let a = run(&pa, [own(20), own(21, responsible: 20)], at: sec)
        #expect(a.samples[pid: 21]?.app == AppKey(kind: .app, id: "b"))
    }

    @Test func nameFallsBackToPathThenComm() {
        var pa = ProcessAssembler(currentUID: testUID)
        var p = own(10, comm: "short")
        p.name = nil
        p.path = "/Applications/Long Name.app/Contents/MacOS/Long Name"
        let a = run(&pa, [p, foreign(11, comm: "trustd", path: "/usr/libexec/trustd-long-name"),
                          foreign(0, comm: "kernel_task", path: .some(nil))], at: sec)
        #expect(a.samples[pid: 10]?.name == "Long Name")
        #expect(a.samples[pid: 11]?.name == "trustd-long-name")   // restricted: path basename when readable
        #expect(a.samples[pid: 0]?.name == "kernel_task")         // else p_comm
    }

    @Test func noProcessTableGivesNoRows() {
        var pa = ProcessAssembler(currentUID: testUID)
        let a = pa.assemble(ProcessInputs(processes: .notRequested, uptimeNs: sec), resolver: resolver)
        #expect(a.samples.isEmpty)
    }
}
