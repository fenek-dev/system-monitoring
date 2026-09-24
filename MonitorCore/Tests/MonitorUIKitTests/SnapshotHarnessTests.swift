import Foundation
import MonitorSnapshotTesting
import SwiftUI
import Testing
@testable import MonitorUIKit

@MainActor @Suite struct SnapshotHarnessTests {
    /// Left half bgCard, right half accent.
    struct Probe: View {
        var body: some View {
            HStack(spacing: 0) {
                TTColor.bgCard
                TTColor.accent
            }
        }
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let px = SnapshotImage.pixels(image)!
        let i = (y * image.width + x) * 4
        return (px[i], px[i + 1], px[i + 2], px[i + 3])
    }

    @Test(arguments: [SnapshotRenderer.Path.imageRenderer, .hosting])
    func rendersAt2xWithTokenColors(path: SnapshotRenderer.Path) throws {
        let image = try #require(SnapshotRenderer.render(Probe(), size: CGSize(width: 40, height: 20), path: path))
        #expect(image.width == 80 && image.height == 40)
        let left = pixel(image, 10, 20), right = pixel(image, 70, 20)
        #expect(left == (0x23, 0x23, 0x26, 255), "bgCard \(left)")
        #expect(right == (0x0A, 0x84, 0xFF, 255), "accent \(right)")
    }

    @Test func pathsAgreeOnPureSwiftUI() throws {
        let view = TTIcon(.cpu, size: 16).padding(2).background(TTColor.bgCard)
        let a = try #require(SnapshotRenderer.render(view, size: CGSize(width: 20, height: 20), path: .imageRenderer))
        let b = try #require(SnapshotRenderer.render(view, size: CGSize(width: 20, height: 20), path: .hosting))
        #expect(SnapshotImage.compare(a, b).fraction < 0.05) // stroke antialiasing differs slightly
    }

    @Test func compareCountsDifferingPixels() throws {
        let a = try #require(SnapshotRenderer.render(TTColor.bgCard, size: CGSize(width: 10, height: 10), path: .imageRenderer))
        let b = try #require(SnapshotRenderer.render(Probe(), size: CGSize(width: 10, height: 10), path: .imageRenderer))
        #expect(SnapshotImage.compare(a, a).fraction == 0)
        let d = SnapshotImage.compare(a, b)
        #expect(abs(d.fraction - 0.5) < 0.01)
        #expect(d.diffImage != nil)
        let c = try #require(SnapshotRenderer.render(Probe(), size: CGSize(width: 12, height: 10), path: .imageRenderer))
        #expect(SnapshotImage.compare(a, c).sizeMismatch)
    }

    @Test func pngRoundTrip() throws {
        let a = try #require(SnapshotRenderer.render(Probe(), size: CGSize(width: 16, height: 8), path: .imageRenderer))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tt-roundtrip-\(UUID()).png")
        try SnapshotRenderer.writePNG(a, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let b = try #require(SnapshotRenderer.readPNG(url).flatMap(SnapshotImage.normalized))
        #expect(SnapshotImage.compare(a, b).fraction == 0)
    }

    @Test func assertSnapshotMatchesGolden() {
        assertSnapshot(Probe(), size: CGSize(width: 24, height: 12), named: "harness-probe")
    }

    @Test func comparisonSheetIsThreeWide() throws {
        let a = try #require(SnapshotRenderer.render(Probe(), size: CGSize(width: 10, height: 10), path: .imageRenderer))
        let sheet = try #require(SnapshotImage.comparisonSheet(reference: a, ours: a, background: CGColor(gray: 0, alpha: 1)))
        #expect(sheet.width == 20 * 3 + 32)
    }
}
