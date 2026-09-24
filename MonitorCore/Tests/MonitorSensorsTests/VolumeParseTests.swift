import Foundation
import Testing
@testable import MonitorSensors
import MonitorModel

@Suite struct VolumeParseTests {
    private func loadFixture(_ name: String) throws -> RawVolumeInfo {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/W6d"))
        return try JSONDecoder().decode(RawVolumeInfo.self, from: Data(contentsOf: url))
    }

    @Test func rootVolumeIDIsTheMountPath() throws {
        // W0a review ruling: VolumeInfo.id must be the mount path so DiskSnapshot.bootVolume finds "/".
        let info = VolumeParser.map(try loadFixture("volume-root"))
        #expect(info.id == "/")
        #expect(info.name == "Macintosh HD")
        #expect(info.bsdName == "disk3s3s1")
        #expect(info.fsType == "apfs")
        #expect(info.busLabel == "Apple Fabric")
        #expect(info.isInternal)
        #expect(!info.isEjectable)
        #expect(!info.isEncrypted)
        #expect(info.totalBytes == 1_995_218_165_760)
        #expect(info.availableBytes == 1_091_344_072_704)
        #expect(info.availableImportantBytes == 1_185_806_311_723)
    }

    @Test func purgeableBytesIsDerivedByVolumeInfoItself() throws {
        let info = VolumeParser.map(try loadFixture("volume-root"))
        // availableImportantBytes - availableBytes (VolumeInfo's own computed property).
        #expect(info.purgeableBytes == 1_185_806_311_723 - 1_091_344_072_704)
    }

    @Test func externalDiskImageIsMarkedExternalAndEjectable() throws {
        let info = VolumeParser.map(try loadFixture("volume-external-dmg"))
        #expect(info.id == "/Volumes/Comfy Desktop")
        #expect(!info.isInternal)
        #expect(info.isEjectable)
        #expect(info.busLabel == "Virtual Interface")
        // availableImportantBytes == 0 here (a real captured value, not "unknown") -> purgeableBytes
        // is 0, not nil: availableImportantBytes(0) <= availableBytes, so the clamp in VolumeInfo
        // itself kicks in.
        #expect(info.purgeableBytes == 0)
    }

    @Test func missingOptionalFieldsFallBackToSafeDefaults() {
        let raw = RawVolumeInfo(mountPath: "/Volumes/Mystery", name: nil, bsdName: nil, fsType: nil, busLabel: nil,
                                 isInternal: nil, isEjectable: nil, isEncrypted: nil, totalBytes: nil,
                                 availableBytes: nil, availableImportantBytes: nil)
        let info = VolumeParser.map(raw)
        #expect(info.id == "/Volumes/Mystery")
        #expect(info.name == "/Volumes/Mystery")
        #expect(info.bsdName == nil)
        // Unknown isInternal defaults to false: an unresolved volume must never be mislabeled as the
        // trusted "internal" case (review fix). Ejectable still defaults to the conservative "not
        // removable" reading.
        #expect(!info.isInternal)
        #expect(!info.isEjectable)
        #expect(info.totalBytes == 0)
        #expect(info.availableBytes == 0)
        #expect(info.availableImportantBytes == nil)
        #expect(info.purgeableBytes == nil)
    }

    @Test func nonLocalVolumeHasNoBSDNameOrBusLabelAndIsNotInternal() {
        // What VolumeSensor produces for a network share (SMB/NFS): it deliberately skips the statfs
        // and IOKit bus-label lookups for a non-local volume (a hung server could block both syscalls
        // well past the sensor's 250 ms budget), so bsdName/busLabel are always nil here.
        let raw = RawVolumeInfo(mountPath: "/Volumes/NetworkShare", name: "NetworkShare", bsdName: nil,
                                 fsType: "smbfs", busLabel: nil, isInternal: false, isEjectable: false,
                                 isEncrypted: false, totalBytes: 1_000_000, availableBytes: 500_000,
                                 availableImportantBytes: nil)
        let info = VolumeParser.map(raw)
        #expect(info.bsdName == nil)
        #expect(info.busLabel == nil)
        #expect(!info.isInternal)
    }

    @Test func rawVolumeInfoDecodesFromJSONIgnoringUnknownKeys() throws {
        // The fixture carries a "_source" documentation key that isn't part of RawVolumeInfo.
        let raw = try loadFixture("volume-root")
        #expect(raw.mountPath == "/")
    }

    /// S-I3: network and hidden mounts are filtered out of the mount table before any capacity call — a dead
    /// SMB/NFS server can't block the sampler.
    @Test func capacityIsFetchedForLocalBrowsableMountsOnly() throws {
        let local = UInt32(MNT_LOCAL), hidden = UInt32(MNT_DONTBROWSE)
        let table: [VolumeSensor.Mount] = [
            .init(path: "/", from: "/dev/disk3s3s1", flags: local),
            .init(path: "/System/Volumes/VM", from: "/dev/disk3s6", flags: local | hidden),
            .init(path: "/Volumes/NAS", from: "//me@nas.local/share", flags: 0),                 // smbfs
            .init(path: "/Volumes/nfs", from: "nas:/export", flags: UInt32(MNT_RDONLY)),         // nfs
            .init(path: "/System/Volumes/Data/home", from: "map auto_home", flags: hidden),      // autofs
            .init(path: "/Volumes/USB", from: "/dev/disk5s1", flags: local),
        ]
        var asked: [String] = []
        let sensor = VolumeSensor(mountTable: { table }) { path in
            asked.append(path)
            return URLResourceValues()
        }
        let reading = try sensor.sample(SampleContext()).reading
        #expect(asked == ["/", "/Volumes/USB"])
        #expect(reading.volumes.map(\.id) == ["/", "/Volumes/USB"])
        #expect(reading.volumes.map(\.bsdName) == ["disk3s3s1", "disk5s1"])
    }

    @Test func bsdNameFromMountSource() {
        #expect(VolumeSensor.bsdName(mountedFrom: "/dev/disk3s3s1") == "disk3s3s1")
        #expect(VolumeSensor.bsdName(mountedFrom: "//me@nas/share") == nil)
        #expect(VolumeSensor.bsdName(mountedFrom: "/dev/") == nil)
        #expect(VolumeSensor.bsdName(mountedFrom: "map auto_home") == nil)
    }

    /// The live table always holds "/" as a local, browsable mount (no file-system call needed to read it).
    @Test func systemMountTableHasLocalRoot() {
        let local = VolumeSensor.localVolumes(VolumeSensor.systemMounts())
        #expect(local.contains { $0.path == "/" && $0.from.hasPrefix("/dev/disk") })
    }
}
