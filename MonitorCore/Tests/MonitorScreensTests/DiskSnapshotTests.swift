import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// DESIGN §3.11 Disk goldens (`__Snapshots__/disk-*.png`).
@MainActor
@Suite("DiskSnapshotTests", .enabled { await ScreenFixture.snapshotsAvailable })
struct DiskSnapshotTests {
    // The mock's sensorsUnavailable/collecting/restricted scenarios render identically to calm on this page, so
    // the unavailable state uses its own fixture and firstTick covers "Collecting…".
    @Test func calm() { assertScreen("disk", scenario: .calm) }

    /// diskIO, volumes and SMART unavailable: strip "—" with reasons, volumes/SSD health/throughput messages.
    @Test func sensorsUnavailable() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.disk = DiskSnapshot(volumes: [])
            f.metrics[.diskRead] = nil
            f.metrics[.diskWrite] = nil
            f.metrics[.diskReadIOPS] = nil
            f.metrics[.diskWriteIOPS] = nil
            f.sensorHealth[.diskIO] = .unavailable("IOBlockStorageDriver statistics not found")
            f.sensorHealth[.volumes] = .unavailable("Volume list unavailable")
            f.sensorHealth[.smart] = .unavailable("SMART data unavailable without root")
            live.apply(f)
        }
        live.isPresenting = true
        let ctx = ShellContext(live: live, settings: ScreenCatalog.snapshotSettings(), history: provider.history(),
                               isSnapshot: true, now: MockDataProvider.referenceDate)
        assertSnapshot(DiskPage().telltaleEnvironment(ctx), size: ScreenSize.pageContent,
                       named: "disk-unavailable")
    }

    /// First tick: one sample → charts "Collecting…", values already shown.
    @Test func firstTick() {
        assertSnapshot(DiskPage().telltaleEnvironment(ScreenFixture.context(.collecting, page: .disk, ticks: 0)),
                       size: ScreenSize.pageContent, named: "disk-firsttick-collecting")
    }

    /// Two volumes (external one ejectable) and SMART status only (no NVMe log without root).
    @Test func externalVolumeStatusOnlySMART() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        let archive = VolumeInfo(id: "/Volumes/Archive", name: "Archive", bsdName: "disk5s1", fsType: "APFS",
                                 busLabel: "USB-C", isEjectable: true, totalBytes: 2_000_000_000_000,
                                 availableBytes: 760_000_000_000, availableImportantBytes: 760_000_000_000)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.disk.volumes.append(archive)
            f.disk.smart = SMARTInfo(model: "APPLE SSD AP1024Z", capacityBytes: 1_000_000_000_000, status: .healthy)
            live.apply(f)
        }
        live.isPresenting = true
        let ctx = ShellContext(live: live, settings: ScreenCatalog.snapshotSettings(), history: provider.history(),
                               isSnapshot: true, now: MockDataProvider.referenceDate)
        assertSnapshot(DiskPage().telltaleEnvironment(ctx), size: ScreenSize.pageContent,
                       named: "disk-external-statusonly")
    }
}

@MainActor
@Suite("DiskPageLogicTests")
struct DiskPageLogicTests {
    private let boot = VolumeInfo(id: "/", name: "Macintosh HD", fsType: "APFS", busLabel: "Internal", isInternal: true,
                                  isEncrypted: true, totalBytes: 994_000_000_000, availableBytes: 382_000_000_000,
                                  availableImportantBytes: 400_000_000_000)

    @Test func subtitle() {
        let full = SMARTInfo(model: "APPLE SSD AP1024Z", capacityBytes: 1_000_000_000_000, status: .healthy,
                             percentageUsed: 2)
        #expect(DiskCopy.subtitle(full) == "Apple SSD · 1 TB · PCIe")
        #expect(DiskCopy.subtitle(SMARTInfo(model: "Samsung 990", capacityBytes: 512_000_000_000)) == "Samsung 990 · 512 GB")
        #expect(DiskCopy.subtitle(nil) == nil)
    }

    @Test func volumeCopyAndSegments() {
        #expect(DiskCopy.volumeDetail(boot) == "Internal · APFS · encrypted")
        #expect(DiskCopy.usage(boot) == "612 GB of 994 GB")
        let seg = DiskCopy.segments(boot)
        #expect(abs(seg.used - 594.0 / 994) < 1e-9)
        #expect(abs(seg.purgeable - 18.0 / 994) < 1e-9)
        let big = VolumeInfo(id: "x", name: "Archive", totalBytes: 2_000_000_000_000, availableBytes: 760_000_000_000)
        #expect(DiskCopy.usage(big) == "1.24 TB of 2 TB")
        #expect(DiskCopy.ordered([big, boot], boot: boot).map(\.name) == ["Macintosh HD", "Archive"])
    }

    @Test func healthBadge() {
        #expect(DiskCopy.health(SMARTInfo(status: .healthy, percentageUsed: 2)) == .healthy)
        #expect(DiskCopy.health(SMARTInfo(status: .healthy, percentageUsed: 80)) == .worn)
        #expect(DiskCopy.health(SMARTInfo(status: .healthy, percentageUsed: 2, criticalWarning: 1)) == .failing)
        #expect(DiskCopy.health(SMARTInfo(status: .unknown)) == nil)
        #expect(DiskCopy.isStatusOnly(SMARTInfo(status: .healthy)))
        #expect(!DiskCopy.isStatusOnly(SMARTInfo(status: .healthy, percentageUsed: 2)))
        #expect(DiskCopy.wear(2) == "2% used")
    }

    /// Eject runs the action and toasts the result (busy / not permitted shown, success confirmed).
    @Test func ejectReportsResult() async {
        let archive = VolumeInfo(id: "/Volumes/Archive", name: "Archive", isEjectable: true)
        let log = PowerDiskCallLog()
        let feedback = ProcessActionFeedback()
        let busy = ProcessActions(eject: { v in log.volumes.append(v.name); return .failed("volume in use") })
        await DiskCopy.eject(archive, actions: busy, feedback: feedback)
        #expect(log.volumes == ["Archive"])
        #expect(feedback.toast == "Couldn't eject Archive: volume in use")
        await DiskCopy.eject(archive, actions: ProcessActions(eject: { _ in .notPermitted }), feedback: feedback)
        #expect(feedback.toast == "Not permitted to eject Archive.")
        await DiskCopy.eject(archive, actions: ProcessActions(eject: { _ in .done }), feedback: feedback)
        #expect(feedback.toast == "Archive ejected.")
    }

    /// CP2: session totals are deltas since Telltale started, not lifetime counters.
    @Test func sessionTotals() {
        let launch: UInt64 = 1_000_000
        let store = DiskSessionBaselines(launchUs: launch)
        // Started before Telltale: baseline at first sight, then deltas (partial).
        var old = ProcessSample(id: ProcessID(pid: 1, startTimeUs: 10), name: "kernel_task",
                                diskReadTotal: 171_400_000_000, diskWriteTotal: 5_000_000_000)
        #expect(store.session(old) == .init(read: 0, write: 0, partial: true))
        old.diskReadTotal = 171_400_000_000 + 2_500_000
        old.diskWriteTotal = 5_000_000_000 + 1_200_000_000
        #expect(store.session(old) == .init(read: 2_500_000, write: 1_200_000_000, partial: true))
        // Started after Telltale: its lifetime counters are session totals.
        let new = ProcessSample(id: ProcessID(pid: 2, startTimeUs: launch + 5), name: "mds_stores",
                                diskReadTotal: 18_400_000_000, diskWriteTotal: 600_000_000)
        #expect(store.session(new) == .init(read: 18_400_000_000, write: 600_000_000, partial: false))
        // observe() baselines idle processes too and drops exited ones.
        let idle = ProcessSample(id: ProcessID(pid: 3, startTimeUs: 20), name: "idle", diskReadTotal: 7, diskWriteTotal: 9)
        store.observe([idle])
        #expect(store.session(idle) == .init(read: 0, write: 0, partial: true))
        // Formatting: storage headline (§5.3), 0 → "—".
        #expect(DiskRows.sessionText(18_400_000_000) == "18.4 GB")
        #expect(DiskRows.sessionText(578_000_000) == "578 MB")
        #expect(DiskRows.sessionText(0) == "—")
        #expect(DiskRows.sessionText(nil) == nil)
        #expect(DiskSessionBaselines.ownStartUs != nil)
    }

    /// A counter that goes backwards rebases (delta 0), and its recovery doesn't spike.
    @Test func sessionCounterRegressionRebases() {
        let store = DiskSessionBaselines(launchUs: 1_000_000)
        var p = ProcessSample(id: ProcessID(pid: 7, startTimeUs: 10), name: "backupd",
                              diskReadTotal: 1_000, diskWriteTotal: 5_000)
        #expect(store.session(p) == .init(read: 0, write: 0, partial: true))
        p.diskReadTotal = 1_600
        p.diskWriteTotal = 5_100
        #expect(store.session(p) == .init(read: 600, write: 100, partial: true))
        p.diskReadTotal = 200                                           // regress
        #expect(store.session(p) == .init(read: 0, write: 100, partial: true))
        p.diskReadTotal = 300                                           // recover: counts from the rebase, no spike
        #expect(store.session(p) == .init(read: 100, write: 100, partial: true))
    }

    /// Exited processes lose their baseline even when the process count stays the same.
    @Test func observePrunesExitedProcesses() {
        let store = DiskSessionBaselines(launchUs: 1_000_000)
        let a = ProcessSample(id: ProcessID(pid: 1, startTimeUs: 10), name: "a", diskReadTotal: 1, diskWriteTotal: 1)
        let b = ProcessSample(id: ProcessID(pid: 2, startTimeUs: 10), name: "b", diskReadTotal: 1, diskWriteTotal: 1)
        let c = ProcessSample(id: ProcessID(pid: 3, startTimeUs: 10), name: "c", diskReadTotal: 1, diskWriteTotal: 1)
        store.observe([a, b])
        #expect(store.hasBaseline(a.id) && store.hasBaseline(b.id))
        store.observe([a, c])                                           // b exited, c spawned: same count
        #expect(!store.hasBaseline(b.id))
        #expect(store.hasBaseline(a.id) && store.hasBaseline(c.id))
    }

    /// CP2 ruling: free = available capacity (container free); purgeable shown separately.
    @Test func freeSpaceExcludesPurgeable() {
        #expect(DiskCopy.freeBytes(boot) == 382_000_000_000)
        #expect(DiskCopy.freeDetail(boot) == "on Macintosh HD · 18 GB purgeable")
        let tb = VolumeInfo(id: "/", name: "Macintosh HD", totalBytes: 2_000_000_000_000, availableBytes: 1_090_000_000_000,
                            availableImportantBytes: 1_090_000_000_000)
        #expect(TTFormat.storage(DiskCopy.freeBytes(tb), style: .capacity) == "1.09 TB")
        #expect(DiskCopy.freeDetail(tb) == "on Macintosh HD")
    }

    @Test func rowsOnlyActiveProcesses() {
        let a = ProcessSample(id: ProcessID(pid: 10, startTimeUs: 1), name: "mds_stores", uid: 0,
                              diskReadBps: 96e6, diskWriteBps: 1.2e6)
        let b = ProcessSample(id: ProcessID(pid: 11, startTimeUs: 1), name: "idle", uid: 501)
        let rows = DiskRows.rows([a, b], identity: { _ in nil }, session: DiskSessionBaselines(launchUs: 0).session)
        #expect(rows.map(\.name) == ["mds_stores"])
        #expect(rows[0].rate == 97.2e6)
        #expect(rows[0].target == .process(pid: 10, name: "mds_stores", path: nil, uid: 0))
    }
}
