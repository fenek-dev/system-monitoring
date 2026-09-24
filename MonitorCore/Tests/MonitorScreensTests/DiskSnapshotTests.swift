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
    @Test func calm() { assertScreen("disk", scenario: .calm) }
    @Test func sensorsUnavailable() { assertScreen("disk", scenario: .sensorsUnavailable) }
    @Test func collecting() { assertScreen("disk", scenario: .collecting) }
    @Test func restricted() { assertScreen("disk", scenario: .restricted) }

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

    @Test func rowsOnlyActiveProcesses() {
        let a = ProcessSample(id: ProcessID(pid: 10, startTimeUs: 1), name: "mds_stores", uid: 0,
                              diskReadBps: 96e6, diskWriteBps: 1.2e6)
        let b = ProcessSample(id: ProcessID(pid: 11, startTimeUs: 1), name: "idle", uid: 501)
        let rows = DiskRows.rows([a, b]) { _ in nil }
        #expect(rows.map(\.name) == ["mds_stores"])
        #expect(rows[0].rate == 97.2e6)
        #expect(rows[0].target == .process(pid: 10, name: "mds_stores", path: nil, uid: 0))
    }
}
