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

    /// Two volumes (external one ejectable), SMART status only (no NVMe log without root), and an "Exited
    /// processes" row.
    @Test func externalVolumeStatusOnlySMART() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        let archive = VolumeInfo(id: "/Volumes/Archive", name: "Archive", bsdName: "disk5s1", fsType: "APFS",
                                 busLabel: "USB-C", isEjectable: true, totalBytes: 2_000_000_000_000,
                                 availableBytes: 760_000_000_000, availableImportantBytes: 760_000_000_000)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.disk.volumes.append(archive)
            // ICR-13 "Exited processes" residual row (no actions).
            f.processes.append(ProcessSample(id: .exitedResidual(7), name: "Exited processes", uid: 0,
                                             diskReadBps: 400_000, diskWriteBps: 150_000,
                                             diskReadSession: 12_000_000, diskWriteSession: 4_000_000))
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

    /// ICR-14: session columns read the engine's `diskReadSession/diskWriteSession` (not the lifetime totals);
    /// storage headline format (§5.3), 0 → "—", nil → "—".
    @Test func sessionColumnsUseEngineSessionFields() {
        let p = ProcessSample(id: ProcessID(pid: 1, startTimeUs: 10), name: "kernel_task", diskReadBps: 1e6,
                              diskReadTotal: 171_400_000_000, diskWriteTotal: 5_000_000_000,
                              diskReadSession: 18_400_000_000, diskWriteSession: 578_000_000)
        let row = DiskRows.rows([p]) { _ in nil }[0]
        #expect(row.readSession == 18_400_000_000 && row.writeSession == 578_000_000)
        #expect(DiskRows.sessionText(row.readSession) == "18.4 GB")
        #expect(DiskRows.sessionText(row.writeSession) == "578 MB")
        #expect(DiskRows.sessionText(0) == "—")
        #expect(DiskRows.sessionText(nil) == nil)
    }

    /// ICR-13: the "Exited processes" residual row is labelled and has no actions.
    @Test func exitedResidualRow() {
        let exited = ProcessSample(id: .exitedResidual(42), name: "Exited processes", uid: 0,
                                   diskReadBps: 2e6, diskReadSession: 9_000_000)
        let row = DiskRows.rows([exited]) { _ in AppIdentity(key: .system, displayName: "System") }[0]
        #expect(row.isExited && row.name == "Exited processes" && row.identity == nil)
    }

    /// CP2 ruling: free = available capacity (`ShellFormat.freeSpace`, container free); purgeable shown separately.
    @Test func freeSpaceExcludesPurgeable() {
        #expect(ShellFormat.freeSpace(boot) == "382 GB")
        #expect(DiskCopy.freeDetail(boot) == "on Macintosh HD · 18 GB purgeable")
        let tb = VolumeInfo(id: "/", name: "Macintosh HD", totalBytes: 2_000_000_000_000, availableBytes: 1_090_000_000_000,
                            availableImportantBytes: 1_090_000_000_000)
        #expect(ShellFormat.freeSpace(tb) == "1.09 TB")
        #expect(DiskCopy.freeDetail(tb) == "on Macintosh HD")
    }

    @Test func rowsOnlyActiveProcesses() {
        let a = ProcessSample(id: ProcessID(pid: 10, startTimeUs: 1), name: "mds_stores", uid: 0,
                              diskReadBps: 96e6, diskWriteBps: 1.2e6)
        let b = ProcessSample(id: ProcessID(pid: 11, startTimeUs: 1), name: "idle", uid: 501)
        let rows = DiskRows.rows([a, b]) { _ in nil }
        #expect(rows.map(\.name) == ["mds_stores"])
        #expect(rows[0].rate == 97.2e6 && !rows[0].isExited)
        #expect(rows[0].target == .process(ProcessID(pid: 10, startTimeUs: 1), name: "mds_stores", path: nil, uid: 0))
    }
}
