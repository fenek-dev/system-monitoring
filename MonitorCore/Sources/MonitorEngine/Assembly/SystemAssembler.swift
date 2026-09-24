import Foundation
import MonitorModel

struct SystemSnapshots: Sendable {
    var cpu = CPUSnapshot()
    var gpu = GPUSnapshot()
    var memory = MemorySnapshot()
    var network = NetworkSnapshot()
    var thermals = ThermalSnapshot()
    var power = PowerSnapshot()
    var disk = DiskSnapshot()
    var metrics = SystemMetrics()
}

/// System-wide snapshots + `SystemMetrics` from one `RawTick` (ARCHITECTURE §3 step 4, §5.5).
/// Counter-based values go through `RateCalculator`s timed by each reading's `capturedNs`.
///
/// Units (W6a, controller 2026-09-24): `MemoryReading` page-class fields (free … anonymous), `total`, compressor and
/// swap fields are bytes; `pageins/pageouts/swapins/swapouts` are cumulative page counts (→ pages/s, DESIGN).
/// `GPUClientsReading.deviceUtilization` is AGX "Device Utilization %" (0–100). It resets on every read by any
/// reader (W6b ruling), so system GPU % comes from IOReport residency; AGX is only the fallback without IOReport.
struct SystemAssembler {
    private enum Counter: Hashable, Sendable {
        case pageins, pageouts, swapins, swapouts
        case ifRx(String), ifTx(String)
        case diskReadBytes(String), diskWriteBytes(String), diskReadOps(String), diskWriteOps(String)
    }

    private var rates = RateCalculator<Counter>()
    private var lastHost: (cores: [CoreTicks], capturedNs: UInt64)?
    private var lastHostUsage: (perCore: [Double], user: Double, system: Double, idle: Double)?

    mutating func reset() {
        rates.reset()
        lastHost = nil
        lastHostUsage = nil
    }

    mutating func assemble(_ tick: RawTick, device: DeviceInfo, processCount: Int?, threadCount: Int?) -> SystemSnapshots {
        var s = SystemSnapshots()
        let soc = tick.soc.value
        var live = Set<Counter>()
        assembleCPU(tick, soc: soc, processCount: processCount, threadCount: threadCount, into: &s)
        assembleGPU(tick, soc: soc, device: device, into: &s)
        assembleMemory(tick.memory, live: &live, into: &s)
        assembleNetwork(tick, live: &live, into: &s)
        assembleThermals(tick, into: &s)
        assemblePower(tick, soc: soc, into: &s)
        assembleDisk(tick, live: &live, into: &s)
        rates.prune(keeping: live)
        return s
    }

    // MARK: - CPU

    private mutating func hostUsage(_ result: SensorResult<HostCPUReading>)
        -> (perCore: [Double], user: Double, system: Double, idle: Double)? {
        guard let r = result.value, let t = result.capturedNs else { return nil }
        if let last = lastHost, last.capturedNs == t { return lastHostUsage }
        let usage = lastHost.flatMap { t > $0.capturedNs ? CPUTicks.usage(previous: $0.cores, current: r.cores) : nil }
        lastHost = (r.cores, t)
        lastHostUsage = usage
        return usage
    }

    private mutating func assembleCPU(_ tick: RawTick, soc: SoCPowerReading?, processCount: Int?, threadCount: Int?,
                                      into s: inout SystemSnapshots) {
        let host = tick.hostCPU.value
        let usage = hostUsage(tick.hostCPU)
        var cpu = CPUSnapshot(processCount: processCount)
        cpu.threadCount = threadCount
        cpu.loadAverage = host.map(\.loadAverage).flatMap { $0.isEmpty ? nil : $0 }
        let kinds = host?.coreKinds ?? []
        if let usage {
            cpu.usage = 1 - usage.idle
            cpu.user = usage.user
            cpu.system = usage.system
            cpu.idle = usage.idle
            if tick.demand.contains(.perCore) {
                cpu.cores = usage.perCore.enumerated().map { i, u in
                    CoreUsage(index: i, kind: i < kinds.count ? kinds[i] : .performance, usage: u)
                }
            }
        }
        for kind in [ClusterKind.efficiency, .performance] {
            let coreKind: CoreKind = kind == .performance ? .performance : .efficiency
            let coreIdx = kinds.indices.filter { kinds[$0] == coreKind }
            let clusters = soc?.clusters.filter { $0.kind == kind } ?? []
            guard !coreIdx.isEmpty || !clusters.isEmpty else { continue }
            var c = ClusterSnapshot(kind: kind, coreCount: coreIdx.count)
            if let usage, !coreIdx.isEmpty, coreIdx.allSatisfy({ $0 < usage.perCore.count }) {
                c.usage = coreIdx.map { usage.perCore[$0] }.reduce(0, +) / Double(coreIdx.count)
            }
            if !clusters.isEmpty {
                c.activeResidency = clusters.map(\.activeFraction).reduce(0, +) / Double(clusters.count)
                c.frequencyMHz = Self.mean(clusters.compactMap(\.frequencyMHz))
                c.maxFrequencyMHz = clusters.compactMap(\.maxFrequencyMHz).max()
                c.watts = Self.total(clusters.map(\.watts))
            }
            cpu.clusters.append(c)
        }
        s.cpu = cpu
        s.metrics[.cpuUsage] = cpu.usage
        s.metrics[.cpuUser] = cpu.user
        s.metrics[.cpuSystem] = cpu.system
        s.metrics[.cpuPCluster] = cpu.clusters.first { $0.kind == .performance }?.usage
        s.metrics[.cpuECluster] = cpu.clusters.first { $0.kind == .efficiency }?.usage
        s.metrics[.loadAvg1] = cpu.loadAverage?.first
    }

    // MARK: - GPU

    private func assembleGPU(_ tick: RawTick, soc: SoCPowerReading?, device: DeviceInfo, into s: inout SystemSnapshots) {
        let agx = tick.gpuClients.value
        var g = GPUSnapshot()
        g.usage = soc?.gpuActiveFraction ?? agx?.deviceUtilization.map { min(1, max(0, $0 / 100)) }
        g.frequencyMHz = soc?.gpuFrequencyMHz
        g.maxFrequencyMHz = soc?.gpuMaxFrequencyMHz
        g.watts = soc?.gpuWatts
        g.aneWatts = soc?.aneWatts
        g.mediaEngines = soc?.mediaEngines ?? []
        g.allocatedMemory = agx?.inUseSystemMemory
        g.coreCount = device.gpuCores
        s.gpu = g
        s.metrics[.gpuUsage] = g.usage
        s.metrics[.gpuFrequency] = g.frequencyMHz
    }

    // MARK: - Memory

    private mutating func assembleMemory(_ result: SensorResult<MemoryReading>, live: inout Set<Counter>,
                                         into s: inout SystemSnapshots) {
        guard let m = result.value, let t = result.capturedNs else { return }
        let add = ProcessAssembler.saturatingAdd
        let app = m.anonymous > m.purgeable ? m.anonymous - m.purgeable : 0
        var snap = MemorySnapshot(total: m.total)
        snap.appMemory = app
        snap.wired = m.wired
        snap.compressed = m.compressorBytes
        snap.used = add(add(app, m.wired), m.compressorBytes)
        snap.cachedFiles = add(m.fileBacked, m.purgeable)
        snap.free = add(m.free, m.speculative)
        if let original = m.compressedOriginalBytes, m.compressorBytes > 0 {
            snap.compressionRatio = Double(original) / Double(m.compressorBytes)
        }
        snap.pressureLevel = m.pressureLevel
        snap.pressureFraction = m.pressureFraction
        snap.swapUsed = m.swapUsed
        snap.swapTotal = m.swapTotal
        snap.swapFileCount = m.swapFileCount
        live.formUnion([.pageins, .pageouts, .swapins, .swapouts])
        snap.pageInsPerSec = rates.rate(for: .pageins, counter: m.pageins, capturedNs: t)
        snap.pageOutsPerSec = rates.rate(for: .pageouts, counter: m.pageouts, capturedNs: t)
        snap.swapInsPerSec = rates.rate(for: .swapins, counter: m.swapins, capturedNs: t)
        snap.swapOutsPerSec = rates.rate(for: .swapouts, counter: m.swapouts, capturedNs: t)
        s.memory = snap
        // Closure form on purpose: an unapplied Double initializer picks `Double(bitPattern:)` for UInt64.
        s.metrics[.memUsed] = snap.used.map { Double($0) }
        s.metrics[.memApp] = snap.appMemory.map { Double($0) }
        s.metrics[.memWired] = snap.wired.map { Double($0) }
        s.metrics[.memCompressed] = snap.compressed.map { Double($0) }
        s.metrics[.memPressure] = snap.pressureFraction
        s.metrics[.memPressureLevel] = snap.pressureLevel.map { Double($0.rawValue) }     // ICR-12
        s.metrics[.swapUsed] = snap.swapUsed.map { Double($0) }
    }

    // MARK: - Network

    private mutating func assembleNetwork(_ tick: RawTick, live: inout Set<Counter>, into s: inout SystemSnapshots) {
        var n = NetworkSnapshot()
        if let r = tick.interfaces.value, let t = tick.interfaces.capturedNs {
            var rx: Double?, tx: Double?
            for i in r.interfaces {
                live.insert(.ifRx(i.bsdName))
                live.insert(.ifTx(i.bsdName))
                let irx = rates.rate(for: .ifRx(i.bsdName), counter: i.rxBytes, capturedNs: t)
                let itx = rates.rate(for: .ifTx(i.bsdName), counter: i.txBytes, capturedNs: t)
                n.interfaces.append(InterfaceSnapshot(bsdName: i.bsdName, displayName: i.displayName, kind: i.kind,
                                                      isUp: i.isUp, isPrimary: i.isPrimary, rxBps: irx, txBps: itx,
                                                      ipv4: i.ipv4, linkRateBps: i.linkRateBps))
                guard i.isUp, !i.bsdName.hasPrefix("lo") else { continue }
                if let irx { rx = (rx ?? 0) + irx }
                if let itx { tx = (tx ?? 0) + itx }
            }
            // System totals = the primary interface (DESIGN): summing double counts bridge members and utun
            // tunnels over en0. Without a usable primary (none, down, or no rate yet — e.g. it just became primary),
            // fall back to the sum over up, non-loopback interfaces.
            if let primary = n.interfaces.first(where: { $0.isPrimary }), primary.isUp,
               primary.rxBps != nil || primary.txBps != nil {
                n.rxBps = primary.rxBps
                n.txBps = primary.txBps
            } else {
                n.rxBps = rx
                n.txBps = tx
            }
            n.routerIPv4 = r.routerIPv4
            n.localIPv4 = (r.interfaces.first { $0.isPrimary && $0.ipv4 != nil } ?? r.interfaces.first { $0.isUp && $0.ipv4 != nil && !$0.bsdName.hasPrefix("lo") })?.ipv4
        }
        n.wifi = tick.wifi.value
        n.latency = tick.latency.value
        s.network = n
        s.metrics[.netRx] = n.rxBps
        s.metrics[.netTx] = n.txBps
        s.metrics[.netLatency] = n.latency?.lastRTTms
    }

    // MARK: - Thermals

    private func assembleThermals(_ tick: RawTick, into s: inout SystemSnapshots) {
        var th = ThermalSnapshot()
        th.pressure = tick.thermalState.value
        let smc = tick.smc.value
        let smcTemps = smc?.temperatures ?? []
        var byGroup: [TemperatureGroup: [Double]] = [:]
        for t in smcTemps { byGroup[t.group, default: []].append(t.celsius) }
        th.groups = TemperatureGroup.allCases.compactMap { g in
            guard let v = byGroup[g], !v.isEmpty else { return nil }
            return TemperatureGroupSnapshot(group: g, average: v.reduce(0, +) / Double(v.count), maximum: v.max()!,
                                            sensorCount: v.count)
        }
        func avg(_ g: TemperatureGroup) -> Double? { th.groups.first { $0.group == g }?.average }
        th.socAverage = avg(.soc) ?? Self.mean([avg(.cpuPerformance), avg(.cpuEfficiency), avg(.gpu)].compactMap { $0 })
        if tick.demand.contains(.rawTemperatures) {
            th.sensors = (tick.temperatures.value?.sensors ?? []) + smcTemps
        }
        th.hottest = (th.sensors.isEmpty ? smcTemps : th.sensors).max { $0.celsius < $1.celsius }
        th.fans = (smc?.fans ?? []).map {
            FanSnapshot(id: $0.index, name: $0.name ?? "Fan \($0.index + 1)", rpm: $0.rpm, minRPM: $0.minRPM, maxRPM: $0.maxRPM)
        }
        // TODO(ICR-6): `th.approximateMapping = !(smc?.catalogMatched ?? true)` once `SMCReading.catalogMatched` lands.
        th.approximateMapping = false
        s.thermals = th
        s.metrics[.socTemp] = th.socAverage
        s.metrics[.cpuPTemp] = avg(.cpuPerformance)
        s.metrics[.cpuETemp] = avg(.cpuEfficiency)
        s.metrics[.gpuTemp] = avg(.gpu)
        s.metrics[.ssdTemp] = avg(.ssd)
        s.metrics[.batteryTemp] = tick.battery.value?.temperatureC ?? avg(.battery)
        let fans = th.fans.sorted { $0.id < $1.id }
        s.metrics[.fan1RPM] = fans.first?.rpm
        s.metrics[.fan2RPM] = fans.count > 1 ? fans[1].rpm : nil
        s.metrics[.thermalPressure] = th.pressure.map { Double($0.rawValue) }
    }

    // MARK: - Power

    private func assemblePower(_ tick: RawTick, soc: SoCPowerReading?, into s: inout SystemSnapshots) {
        var p = PowerSnapshot()
        p.cpuWatts = soc?.cpuWatts
        p.gpuWatts = soc?.gpuWatts
        p.aneWatts = soc?.aneWatts
        p.dramWatts = soc?.dramWatts
        p.packageWatts = Self.total([soc?.cpuWatts, soc?.gpuWatts, soc?.aneWatts])
        let smc = tick.smc.value
        p.systemWatts = smc?.systemWatts
        p.adapterWatts = smc?.adapterWatts
        if let b = tick.battery.value {
            p.lowPowerMode = b.lowPowerMode
            p.adapterName = b.adapterName
            if b.present {
                var bs = BatterySnapshot(percent: b.percent, isCharging: b.isCharging, onAC: b.onAC)
                let minutes = b.isCharging ? b.minutesToFull : (b.onAC ? nil : b.minutesToEmpty)
                bs.timeRemaining = minutes.map { .seconds($0 * 60) }
                if let maxC = b.maxCapacityWh, let design = b.designCapacityWh, design > 0 { bs.healthFraction = maxC / design }
                bs.cycleCount = b.cycleCount
                bs.condition = b.condition
                bs.maxCapacityWh = b.maxCapacityWh
                bs.designCapacityWh = b.designCapacityWh
                bs.currentCapacityWh = b.currentCapacityWh
                bs.temperatureC = b.temperatureC
                if let v = b.voltageV, let a = b.amperageA, a < 0 { bs.drainWatts = v * -a }
                p.battery = bs
            }
        }
        s.power = p
        s.metrics[.packageWatts] = p.packageWatts
        s.metrics[.cpuWatts] = p.cpuWatts
        s.metrics[.gpuWatts] = p.gpuWatts
        s.metrics[.aneWatts] = p.aneWatts
        s.metrics[.dramWatts] = p.dramWatts
        s.metrics[.systemWatts] = p.systemWatts
        s.metrics[.batteryPercent] = p.battery?.percent
    }

    // MARK: - Disk

    private mutating func assembleDisk(_ tick: RawTick, live: inout Set<Counter>, into s: inout SystemSnapshots) {
        var d = DiskSnapshot()
        if let r = tick.diskIO.value, let t = tick.diskIO.capturedNs {
            var rb: Double?, wb: Double?, ro: Double?, wo: Double?
            for (i, drv) in r.drivers.enumerated() where Self.countsTowardDiskTotals(drv) {
                let name = drv.bsdName ?? "#\(i)"
                let keys: [Counter] = [.diskReadBytes(name), .diskWriteBytes(name), .diskReadOps(name), .diskWriteOps(name)]
                live.formUnion(keys)
                if let v = rates.rate(for: keys[0], counter: drv.readBytes, capturedNs: t) { rb = (rb ?? 0) + v }
                if let v = rates.rate(for: keys[1], counter: drv.writeBytes, capturedNs: t) { wb = (wb ?? 0) + v }
                if let v = rates.rate(for: keys[2], counter: drv.readOps, capturedNs: t) { ro = (ro ?? 0) + v }
                if let v = rates.rate(for: keys[3], counter: drv.writeOps, capturedNs: t) { wo = (wo ?? 0) + v }
            }
            d.readBps = rb
            d.writeBps = wb
            d.readIOPS = ro
            d.writeIOPS = wo
        }
        d.volumes = tick.volumes.value?.volumes ?? []
        d.smart = tick.smart.value
        s.disk = d
        s.metrics[.diskRead] = d.readBps
        s.metrics[.diskWrite] = d.writeBps
        s.metrics[.diskReadIOPS] = d.readIOPS
        s.metrics[.diskWriteIOPS] = d.writeIOPS
    }

    // MARK: - Helpers

    /// Disk-image (DMG) drivers are excluded: their I/O is also counted on the physical disk underneath.
    /// ICR-11: a mounted disk image's driver reports the same I/O as the physical disk under it — count only the
    /// physical one.
    static func countsTowardDiskTotals(_ driver: BlockDriverCounter) -> Bool {
        !driver.isDiskImage
    }

    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// Sum of the non-nil values; nil when all are nil.
    static func total(_ v: [Double?]) -> Double? {
        let present = v.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }
}
