import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

private func fresh<R>(_ r: R, _ t: UInt64) -> SensorResult<R> { .fresh(r, capturedNs: t) }

private let device = DeviceInfo(performanceCores: 2, efficiencyCores: 1, gpuCores: 32)

@Suite struct SystemAssemblerTests {
    private func assemble(_ sa: inout SystemAssembler, _ tick: RawTick) -> SystemSnapshots {
        sa.assemble(tick, device: device, processCount: 3, threadCount: 12)
    }

    // MARK: CPU

    private func host(_ busy: [UInt64], idle: [UInt64]) -> HostCPUReading {
        HostCPUReading(cores: zip(busy, idle).map { CoreTicks(user: $0, system: 0, idle: $1) },
                       coreKinds: [.performance, .performance, .efficiency], loadAverage: [2.5, 2, 1])
    }

    @Test func cpuFromHostTicksAndClusters() throws {
        var sa = SystemAssembler()
        let soc = SoCPowerReading(interval: .seconds(1), cpuWatts: 5, clusters: [
            ClusterResidency(name: "ECPU", kind: .efficiency, activeFraction: 0.2, frequencyMHz: 1_000, maxFrequencyMHz: 2_064, watts: 0.3),
            ClusterResidency(name: "PCPU", kind: .performance, activeFraction: 0.6, frequencyMHz: 3_000, maxFrequencyMHz: 3_228, watts: 3),
            ClusterResidency(name: "PCPU1", kind: .performance, activeFraction: 0.4, frequencyMHz: 2_000, maxFrequencyMHz: 3_228, watts: 1),
        ])
        let first = assemble(&sa, RawTick(uptimeNs: sec, hostCPU: fresh(host([0, 0, 0], idle: [0, 0, 0]), sec)))
        #expect(first.cpu.usage == nil)                        // first sight: no rates
        #expect(first.cpu.loadAverage == [2.5, 2, 1])
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, demand: .perCore,
                                      hostCPU: fresh(host([50, 100, 10], idle: [50, 0, 90]), 2 * sec), soc: fresh(soc, 2 * sec)))
        #expect(abs(try #require(s.cpu.usage) - 160.0 / 300) < 1e-12)
        #expect(s.cpu.cores.map(\.usage) == [0.5, 1.0, 0.1])
        #expect(s.cpu.cores.map(\.kind) == [.performance, .performance, .efficiency])
        #expect(s.cpu.processCount == 3 && s.cpu.threadCount == 12)
        let p = try #require(s.cpu.clusters.first { $0.kind == .performance })
        #expect(p.coreCount == 2)
        #expect(p.usage == 0.75)
        #expect(abs(try #require(p.activeResidency) - 0.5) < 1e-12)
        #expect(p.frequencyMHz == 2_500)
        #expect(p.maxFrequencyMHz == 3_228)
        #expect(p.watts == 4)
        let e = try #require(s.cpu.clusters.first { $0.kind == .efficiency })
        #expect(e.coreCount == 1 && e.usage == 0.1 && e.watts == 0.3)
        #expect(s.metrics[.cpuUsage] == s.cpu.usage)
        #expect(s.metrics[.cpuPCluster] == 0.75)
        #expect(s.metrics[.cpuECluster] == 0.1)
        #expect(s.metrics[.loadAvg1] == 2.5)
    }

    @Test func perCoreOnlyWithDemand() {
        var sa = SystemAssembler()
        _ = assemble(&sa, RawTick(uptimeNs: sec, hostCPU: fresh(host([0, 0, 0], idle: [0, 0, 0]), sec)))
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, hostCPU: fresh(host([1, 1, 1], idle: [1, 1, 1]), 2 * sec)))
        #expect(s.cpu.cores.isEmpty)
        #expect(s.cpu.usage == 0.5)
    }

    @Test func cachedHostReadingKeepsUsage() {
        var sa = SystemAssembler()
        _ = assemble(&sa, RawTick(uptimeNs: sec, hostCPU: fresh(host([0, 0, 0], idle: [0, 0, 0]), sec)))
        _ = assemble(&sa, RawTick(uptimeNs: 2 * sec, hostCPU: fresh(host([1, 1, 1], idle: [1, 1, 1]), 2 * sec)))
        let s = assemble(&sa, RawTick(uptimeNs: 3 * sec, hostCPU: .cached(host([1, 1, 1], idle: [1, 1, 1]), capturedNs: 2 * sec)))
        #expect(s.cpu.usage == 0.5)
    }

    // MARK: GPU

    @Test func gpuFromIOReportElseAGX() {
        var sa = SystemAssembler()
        let soc = SoCPowerReading(gpuWatts: 7, aneWatts: 0.5, gpuActiveFraction: 0.4, gpuFrequencyMHz: 900, gpuMaxFrequencyMHz: 1_296)
        let s = assemble(&sa, RawTick(soc: fresh(soc, sec), gpuClients: fresh(GPUClientsReading(deviceUtilization: 80, inUseSystemMemory: 1 << 30), sec)))
        #expect(s.gpu.usage == 0.4 && s.gpu.watts == 7 && s.gpu.frequencyMHz == 900 && s.gpu.aneWatts == 0.5)
        #expect(s.gpu.allocatedMemory == 1 << 30)
        #expect(s.gpu.coreCount == 32)
        #expect(s.metrics[.gpuUsage] == 0.4 && s.metrics[.gpuFrequency] == 900)
        let fallback = assemble(&sa, RawTick(gpuClients: fresh(GPUClientsReading(deviceUtilization: 80), sec)))
        #expect(fallback.gpu.usage == 0.8)                     // AGX "Device Utilization %" is 0–100
        #expect(assemble(&sa, RawTick()).gpu.usage == nil)
    }

    // MARK: Memory

    @Test func memoryComposition() throws {
        var sa = SystemAssembler()
        // page-class fields are bytes (pages × pageSize); pageins/outs are page counts
        let page: UInt64 = 16_384
        var m = MemoryReading(pageSize: page, total: 24 << 30, free: 100 * page, speculative: 20 * page, wired: 1_000 * page,
                              purgeable: 50 * page, fileBacked: 400 * page, anonymous: 3_050 * page,
                              compressorBytes: 200 * page,
                              compressedOriginalBytes: 560 * page, pageins: 10, pageouts: 0, swapins: 0, swapouts: 0,
                              swapTotal: 2 << 30, swapUsed: 1 << 30, swapFileCount: 2, pressureLevel: .warning,
                              pressureFraction: 0.62)
        _ = assemble(&sa, RawTick(uptimeNs: sec, memory: fresh(m, sec)))
        m.pageins = 30
        m.pageouts = 4
        let all = assemble(&sa, RawTick(uptimeNs: 3 * sec, memory: fresh(m, 3 * sec)))
        #expect(all.metrics[.memUsed] == Double(4_200 * page))   // regression: not Double(bitPattern:)
        #expect(all.metrics[.swapUsed] == Double(1 << 30))
        #expect(all.metrics[.memPressureLevel] == 2)                // ICR-12: MemoryPressureLevel.warning.rawValue
        let s = all.memory
        #expect(s.total == 24 << 30)
        #expect(s.appMemory == 3_000 * page)
        #expect(s.wired == 1_000 * page)
        #expect(s.compressed == 200 * page)
        #expect(s.used == 4_200 * page)
        #expect(s.cachedFiles == 450 * page)
        #expect(s.free == 120 * page)
        #expect(s.compressionRatio == 2.8)
        #expect(s.pressureLevel == .warning && s.pressureFraction == 0.62)
        #expect(s.swapUsed == 1 << 30 && s.swapTotal == 2 << 30 && s.swapFileCount == 2)
        #expect(s.pageInsPerSec == 10 && s.pageOutsPerSec == 2 && s.swapInsPerSec == 0)
    }

    @Test func memoryMissingIsEmpty() {
        var sa = SystemAssembler()
        let s = assemble(&sa, RawTick())
        #expect(s.memory.used == nil)
        #expect(s.metrics[.memUsed] == nil)
    }

    // MARK: Network

    @Test func networkRatesPerInterface() throws {
        var sa = SystemAssembler()
        func r(_ rx: UInt64, _ tx: UInt64) -> InterfacesReading {
            InterfacesReading(interfaces: [
                InterfaceCounter(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi, isUp: true, isPrimary: true,
                                 rxBytes: rx, txBytes: tx, ipv4: "192.168.1.5"),
                InterfaceCounter(bsdName: "lo0", displayName: "Loopback", isUp: true, rxBytes: rx * 10, txBytes: tx * 10),
                InterfaceCounter(bsdName: "en5", displayName: "Ethernet", kind: .ethernet, isUp: false, rxBytes: 7, txBytes: 7),
            ], routerIPv4: "192.168.1.1")
        }
        _ = assemble(&sa, RawTick(uptimeNs: sec, interfaces: fresh(r(1_000, 100), sec)))
        let latency = LatencyReading(target: "1.1.1.1", lastRTTms: 12)
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, interfaces: fresh(r(3_000, 300), 2 * sec),
                                      wifi: fresh(WiFiInfo(interface: "en0", rssi: -50), 2 * sec),
                                      latency: fresh(latency, 2 * sec))).network
        #expect(s.rxBps == 2_000 && s.txBps == 200)          // loopback and down interfaces excluded
        #expect(s.interfaces.first { $0.bsdName == "en0" }?.rxBps == 2_000)
        #expect(s.routerIPv4 == "192.168.1.1")
        #expect(s.localIPv4 == "192.168.1.5")
        #expect(s.wifi?.rssi == -50)
        #expect(s.latency == latency)
    }

    @Test func networkTotalsUsePrimaryInterfaceOnly() {
        var sa = SystemAssembler()
        func r(_ k: UInt64, primary: Bool) -> InterfacesReading {
            InterfacesReading(interfaces: [
                InterfaceCounter(bsdName: "en0", kind: .wifi, isUp: true, isPrimary: primary, rxBytes: k * 1_000, txBytes: k * 100),
                InterfaceCounter(bsdName: "utun3", isUp: true, rxBytes: k * 1_000, txBytes: k * 100),     // VPN over en0
                InterfaceCounter(bsdName: "bridge0", kind: .thunderbolt, isUp: true, rxBytes: k * 50, txBytes: 0),
            ])
        }
        _ = assemble(&sa, RawTick(uptimeNs: sec, interfaces: fresh(r(1, primary: true), sec)))
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, interfaces: fresh(r(2, primary: true), 2 * sec))).network
        #expect(s.rxBps == 1_000 && s.txBps == 100)                 // not 2 050 / 200
        var noPrimary = SystemAssembler()
        _ = assemble(&noPrimary, RawTick(uptimeNs: sec, interfaces: fresh(r(1, primary: false), sec)))
        let f = assemble(&noPrimary, RawTick(uptimeNs: 2 * sec, interfaces: fresh(r(2, primary: false), 2 * sec))).network
        #expect(f.rxBps == 2_050)                                   // fallback: sum of up, non-loopback
    }

    @Test func networkTotalsFallBackToSumWhenPrimaryHasNoRate() {
        // en0 was not primary at tick 1; utun3 becomes primary at tick 2 (first sight → no rate yet).
        var sa = SystemAssembler()
        _ = assemble(&sa, RawTick(uptimeNs: sec, interfaces: fresh(InterfacesReading(interfaces: [
            InterfaceCounter(bsdName: "en0", kind: .wifi, isUp: true, isPrimary: true, rxBytes: 1_000, txBytes: 100),
        ]), sec)))
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, interfaces: fresh(InterfacesReading(interfaces: [
            InterfaceCounter(bsdName: "en0", kind: .wifi, isUp: true, rxBytes: 3_000, txBytes: 300),
            InterfaceCounter(bsdName: "en7", isUp: true, isPrimary: true, rxBytes: 9_999, txBytes: 9_999),
        ]), 2 * sec))).network
        #expect(s.rxBps == 2_000 && s.txBps == 200)                 // en0's rate, not nil
        // Primary down → sum over up interfaces.
        var down = SystemAssembler()
        func r(_ k: UInt64) -> InterfacesReading {
            InterfacesReading(interfaces: [
                InterfaceCounter(bsdName: "en0", kind: .wifi, isUp: false, isPrimary: true, rxBytes: k, txBytes: k),
                InterfaceCounter(bsdName: "en5", isUp: true, rxBytes: k * 500, txBytes: k * 50),
            ])
        }
        _ = assemble(&down, RawTick(uptimeNs: sec, interfaces: fresh(r(1), sec)))
        let d = assemble(&down, RawTick(uptimeNs: 2 * sec, interfaces: fresh(r(2), 2 * sec))).network
        #expect(d.rxBps == 500 && d.txBps == 50)
    }

    @Test func diskImageDriversAreExcludedFromTotals() {
        // With a disk image mounted, its driver (disk4, isDiskImage) and the physical disk both report the I/O;
        // totals must count the physical disk only (ICR-11).
        var sa = SystemAssembler()
        func r(_ k: UInt64) -> DiskIOReading {
            DiskIOReading(drivers: [
                BlockDriverCounter(bsdName: "disk0", isInternal: true, readOps: k, writeOps: k,
                                   readBytes: 4_096 * k, writeBytes: 8_192 * k),
                BlockDriverCounter(bsdName: "disk4", isInternal: false, readOps: k, writeOps: k,
                                   readBytes: 4_096 * k, writeBytes: 8_192 * k, isDiskImage: true),
            ])
        }
        _ = assemble(&sa, RawTick(uptimeNs: sec, diskIO: fresh(r(10), sec)))
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, diskIO: fresh(r(20), 2 * sec))).disk
        #expect(s.readBps == 40_960 && s.writeBps == 81_920)          // disk0 only, not doubled
        #expect(s.readIOPS == 10 && s.writeIOPS == 10)
        #expect(SystemAssembler.countsTowardDiskTotals(BlockDriverCounter(bsdName: "disk4", isDiskImage: true)) == false)
        #expect(SystemAssembler.countsTowardDiskTotals(BlockDriverCounter(bsdName: "disk0")))
    }

    // MARK: Thermals

    @Test func thermalGroupsFromSMCAndRawListOnlyOnDemand() throws {
        var sa = SystemAssembler()
        let smc = SMCReading(fans: [RawFan(index: 0, rpm: 1_200, minRPM: 1_000, maxRPM: 5_000)],
                             temperatures: [RawTemperature(name: "Tp01", celsius: 60, group: .cpuPerformance),
                                            RawTemperature(name: "Tp05", celsius: 70, group: .cpuPerformance),
                                            RawTemperature(name: "Tg0f", celsius: 50, group: .gpu),
                                            RawTemperature(name: "Ts0S", celsius: 40, group: .soc)],
                             systemWatts: 22, adapterWatts: 60)
        let hid = TemperatureReading(sensors: [RawTemperature(name: "PMU tdie1", celsius: 75, group: .soc, source: .hid)])
        let s = assemble(&sa, RawTick(temperatures: fresh(hid, sec), smc: fresh(smc, sec), thermalState: fresh(.fair, sec)))
        #expect(s.thermals.pressure == .fair)
        let p = try #require(s.thermals.groups.first { $0.group == .cpuPerformance })
        #expect(p.average == 65 && p.maximum == 70 && p.sensorCount == 2)
        #expect(s.thermals.groups.map(\.group) == [.cpuPerformance, .gpu, .soc])   // TemperatureGroup order
        #expect(s.thermals.hottest?.name == "Tp05")
        #expect(s.thermals.socAverage == 40)
        #expect(s.thermals.sensors.isEmpty)                    // no .rawTemperatures demand
        #expect(s.thermals.fans == [FanSnapshot(id: 0, name: "Fan 1", rpm: 1_200, minRPM: 1_000, maxRPM: 5_000)])
        #expect(s.metrics[.cpuPTemp] == 65 && s.metrics[.gpuTemp] == 50 && s.metrics[.socTemp] == 40)
        #expect(s.metrics[.fan1RPM] == 1_200 && s.metrics[.fan2RPM] == nil)
        #expect(s.metrics[.thermalPressure] == 1)
        let raw = assemble(&sa, RawTick(demand: .rawTemperatures, temperatures: fresh(hid, sec), smc: fresh(smc, sec)))
        #expect(raw.thermals.sensors.count == 5)
        #expect(raw.thermals.hottest?.name == "PMU tdie1")
    }

    @Test func thermalsMissing() {
        var sa = SystemAssembler()
        let t = assemble(&sa, RawTick()).thermals
        #expect(t.pressure == nil && t.groups.isEmpty && t.socAverage == nil)
    }

    // MARK: Power

    @Test func powerAndBattery() throws {
        var sa = SystemAssembler()
        let soc = SoCPowerReading(cpuWatts: 3, gpuWatts: 2, aneWatts: 0.5, dramWatts: 0.7)
        let bat = BatteryReading(present: true, percent: 80, isCharging: false, onAC: false, minutesToEmpty: 300,
                                 cycleCount: 120, designCapacityWh: 100, maxCapacityWh: 90, currentCapacityWh: 72,
                                 voltageV: 12, amperageA: -1.5, temperatureC: 31, condition: "Normal",
                                 adapterName: nil, lowPowerMode: true)
        let s = assemble(&sa, RawTick(soc: fresh(soc, sec), smc: fresh(SMCReading(systemWatts: 20, adapterWatts: nil), sec),
                                      battery: fresh(bat, sec)))
        #expect(s.power.packageWatts == 5.5)
        #expect(s.power.dramWatts == 0.7)
        #expect(s.power.systemWatts == 20)
        #expect(s.power.lowPowerMode)
        let b = try #require(s.power.battery)
        #expect(b.percent == 80 && b.timeRemaining == .seconds(300 * 60) && b.healthFraction == 0.9)
        #expect(b.drainWatts == 18)
        #expect(b.temperatureC == 31)
        #expect(s.metrics[.packageWatts] == 5.5 && s.metrics[.batteryPercent] == 80 && s.metrics[.systemWatts] == 20)
        #expect(s.metrics[.batteryTemp] == 31)
    }

    @Test func noBatteryMeansNilSnapshot() {
        var sa = SystemAssembler()
        let s = assemble(&sa, RawTick(battery: fresh(BatteryReading(present: false), sec)))
        #expect(s.power.battery == nil)
        #expect(s.power.packageWatts == nil)
    }

    @Test func chargingBatteryHasNoDrainAndTimeToFull() {
        var sa = SystemAssembler()
        let bat = BatteryReading(present: true, percent: 50, isCharging: true, onAC: true, minutesToFull: 40,
                                 voltageV: 12, amperageA: 2, adapterName: "96W USB-C")
        let s = assemble(&sa, RawTick(battery: fresh(bat, sec)))
        #expect(s.power.battery?.drainWatts == nil)
        #expect(s.power.battery?.timeRemaining == .seconds(40 * 60))
        #expect(s.power.adapterName == "96W USB-C")
    }

    // MARK: Disk

    @Test func diskRates() {
        var sa = SystemAssembler()
        func r(_ k: UInt64) -> DiskIOReading {
            DiskIOReading(drivers: [BlockDriverCounter(bsdName: "disk0", isInternal: true, readOps: k, writeOps: 2 * k,
                                                       readBytes: 4_096 * k, writeBytes: 8_192 * k),
                                    BlockDriverCounter(bsdName: "disk4", isInternal: false, readOps: k, writeOps: 0,
                                                       readBytes: 1_000 * k, writeBytes: 0)])
        }
        _ = assemble(&sa, RawTick(uptimeNs: sec, diskIO: fresh(r(10), sec)))
        let vols = VolumesReading(volumes: [VolumeInfo(id: "/", name: "Macintosh HD", isInternal: true, totalBytes: 1_000, availableBytes: 400)])
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, diskIO: fresh(r(20), 2 * sec), volumes: fresh(vols, 2 * sec),
                                      smart: fresh(SMARTInfo(status: .healthy), 2 * sec))).disk
        #expect(s.readBps == 50_960 && s.writeBps == 81_920)
        #expect(s.readIOPS == 20 && s.writeIOPS == 20)
        #expect(s.bootVolume?.name == "Macintosh HD")
        #expect(s.smart?.status == .healthy)
    }

    @Test func resetDropsBaselines() {
        var sa = SystemAssembler()
        _ = assemble(&sa, RawTick(uptimeNs: sec, hostCPU: fresh(host([0, 0, 0], idle: [0, 0, 0]), sec)))
        sa.reset()
        let s = assemble(&sa, RawTick(uptimeNs: 2 * sec, hostCPU: fresh(host([1, 1, 1], idle: [1, 1, 1]), 2 * sec)))
        #expect(s.cpu.usage == nil)
    }
}
