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
        // Unknown internal/ejectable defaults to the conservative "internal, non-ejectable" reading
        // rather than mislabeling an ordinary volume as removable external media.
        #expect(info.isInternal)
        #expect(!info.isEjectable)
        #expect(info.totalBytes == 0)
        #expect(info.availableBytes == 0)
        #expect(info.availableImportantBytes == nil)
        #expect(info.purgeableBytes == nil)
    }

    @Test func rawVolumeInfoDecodesFromJSONIgnoringUnknownKeys() throws {
        // The fixture carries a "_source" documentation key that isn't part of RawVolumeInfo.
        let raw = try loadFixture("volume-root")
        #expect(raw.mountPath == "/")
    }
}
