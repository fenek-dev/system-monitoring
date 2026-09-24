import Foundation
import MonitorModel

/// `RawTick` → `SystemFrame` (ARCHITECTURE §3 step 4). Order: coalition deltas → processes (rusage v6, AGX, NStat,
/// ps RSS) → `CoalitionAttributor` (restricted coalitions only) → `EnergyAttributor` (v6 → coalition residual → SoC
/// share) → grouping + session totals → system snapshots. `alert`/`events` are filled by the caller.
public struct FrameAssembler {
    private let resolver: any AppResolving
    private var energy: any EnergyAttributor
    private var processes: ProcessAssembler
    private var system = SystemAssembler()
    private var coalitionTracker = CoalitionTracker()
    private var coalitionAttributor = CoalitionAttributor()
    private var coalitionClock = CaptureClock()
    private var session = SessionAccumulator()
    private var connectionRx = RateCalculator<UInt64>()
    private var connectionTx = RateCalculator<UInt64>()
    private var lastUptimeNs: UInt64?
    private var lastDevice: DeviceInfo?

    public init(resolver: any AppResolving, energy: any EnergyAttributor = RulingEnergyAttributor(), currentUID: uid_t = getuid()) {
        self.resolver = resolver
        self.energy = energy
        self.processes = ProcessAssembler(currentUID: currentUID)
    }

    /// Drops every baseline (sleep/wake, unpause): the next frame has no rates. Session totals are kept.
    public mutating func reset() {
        processes.reset()
        system.reset()
        coalitionTracker.reset()
        coalitionClock.reset()
        connectionRx.reset()
        connectionTx.reset()
        lastUptimeNs = nil
    }

    public mutating func assemble(_ tick: RawTick, inspectedApp: AppKey?) -> SystemFrame {
        var frame = SystemFrame(wallTime: tick.wallTime, uptimeNs: tick.uptimeNs, mode: tick.mode)
        if let last = lastUptimeNs, tick.uptimeNs > last { frame.interval = .nanoseconds(Int64(tick.uptimeNs - last)) }
        lastUptimeNs = tick.uptimeNs
        if let d = tick.device.value { lastDevice = d }
        frame.device = lastDevice ?? .placeholder
        frame.sensorHealth = tick.health

        // Coalitions → deltas (own interval) and pid membership.
        let coalitionDeltas = coalitionTracker.deltas(tick.coalitions)
        let coalitionAdvanced = coalitionClock.advance(to: tick.coalitions.capturedNs).advanced

        // Processes.
        var pa = processes.assemble(ProcessInputs(
            processes: tick.processes, gpuClients: tick.gpuClients, flows: tick.networkFlows, rootMemory: tick.rootMemory,
            assertions: tick.sleepAssertions, coalitionOf: coalitionTracker.pidToCoalition(tick.coalitions),
            uptimeNs: tick.uptimeNs), resolver: resolver)

        // Coalition residual (restricted coalitions only).
        var rows = pa.samples
        if let coalitionDeltas {
            rows += coalitionAttributor.attribute(&rows, coalitions: coalitionDeltas, identities: pa.identityByPID)
        }

        // Energy: v6 → coalition residual → SoC share; estimated per row (ICR-5).
        let watts = energy.watts(processes: rows, coalitions: coalitionDeltas ?? CoalitionDeltas(), soc: tick.soc.value,
                                 dt: pa.interval ?? 0)
        let estimated = energy.estimatedIDs
        for i in rows.indices {
            rows[i].energyWatts = watts[rows[i].id]
            rows[i].energyEstimated = rows[i].energyWatts != nil && estimated.contains(rows[i].id)
        }

        // Identities for synthetic rows' apps.
        for r in rows where r.id.isSynthetic && pa.identities[r.app] == nil {
            pa.identities[r.app] = AppGrouper.defaultIdentity(r.app)
        }

        // Session totals: only readings that advanced this tick contribute.
        var byApp: [AppKey: ProcessDelta] = [:]
        for r in rows {
            if let d = pa.deltas[r.id] { byApp[r.app, default: ProcessDelta()].accumulate(d) }
            if r.provenance == .coalition, coalitionAdvanced, let cid = r.coalitionID,
               let secs = coalitionDeltas?.byID[cid]?.seconds, let cpu = r.cpuPercent {
                byApp[r.app, default: ProcessDelta()].accumulate(ProcessDelta(cpuNs: UInt64((cpu / 100 * secs * 1e9).rounded())))
            }
        }
        if pa.unattributedDelta != ProcessDelta() { byApp[.system, default: ProcessDelta()].accumulate(pa.unattributedDelta) }
        session.add(byApp: byApp)

        var apps = AppGrouper.group(rows, identities: pa.identities, unattributed: pa.unattributed)
        for i in apps.indices {
            let t = session.totals(apps[i].identity.key)
            apps[i].cpuTimeNs = t.cpuNs
            apps[i].gpuTimeNs = t.gpuNs
            apps[i].netRxSession = t.rx
            apps[i].netTxSession = t.tx
        }

        frame.connections = connections(tick.networkFlows, inspectedApp: inspectedApp, rows: pa.samples,
                                        owners: pa.flowOwners)

        let realRows = pa.samples
        let threads = realRows.reduce(0) { $0 + Int($1.threads ?? 0) }
        let snaps = system.assemble(tick, device: frame.device, processCount: tick.processes.value == nil ? nil : realRows.count,
                                    threadCount: tick.processes.value == nil ? nil : threads)
        frame.cpu = snaps.cpu
        frame.gpu = snaps.gpu
        frame.memory = snaps.memory
        frame.network = snaps.network
        frame.thermals = snaps.thermals
        frame.power = snaps.power
        frame.disk = snaps.disk
        frame.metrics = snaps.metrics
        frame.processes = rows
        frame.apps = apps
        return frame
    }

    // MARK: - Connections (inspected app only)

    private mutating func connections(_ result: SensorResult<NetworkFlowsReading>, inspectedApp: AppKey?,
                                      rows: [ProcessSample], owners: [ProcessID: ProcessID]) -> [ConnectionSample] {
        guard let inspectedApp, let reading = result.value, let t = result.capturedNs else {
            connectionRx.reset()
            connectionTx.reset()
            return []
        }
        var appOf: [ProcessID: AppKey] = [:]
        for r in rows where r.app == inspectedApp { appOf[r.id] = inspectedApp }
        var out: [ConnectionSample] = []
        var live = Set<UInt64>()
        for f in reading.flows {
            guard let owner = owners[f.process], appOf[owner] != nil else { continue }
            live.insert(f.flowID)
            out.append(ConnectionSample(
                id: f.flowID, process: owner, app: inspectedApp, proto: f.proto, localPort: f.localPort,
                remoteAddress: f.remoteAddress, remotePort: f.remotePort, tcpState: f.tcpState,
                rxBps: connectionRx.rate(for: f.flowID, counter: f.rxBytes, capturedNs: t),
                txBps: connectionTx.rate(for: f.flowID, counter: f.txBytes, capturedNs: t),
                rxTotal: f.rxBytes, txTotal: f.txBytes))
        }
        connectionRx.prune(keeping: live)
        connectionTx.prune(keeping: live)
        return out.sorted { ($0.rxBps ?? 0) + ($0.txBps ?? 0) > ($1.rxBps ?? 0) + ($1.txBps ?? 0) }
    }
}
