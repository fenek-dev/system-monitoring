import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Offscreen rendering for snapshot tests and `telltale-render` (no Testing import).
/// Determinism (ARCHITECTURE §8): `isSnapshot = true`, en_US, Europe/London, dark, scale 2.
@MainActor public enum SnapshotRenderer {
    public enum Path: Sendable { case imageRenderer, hosting }

    /// See `TTTextRendering.configure()`.
    public nonisolated static func configureTextRendering() { TTTextRendering.configure() }

    public static let locale = Locale(identifier: "en_US")
    public static let timeZone = TimeZone(identifier: "Europe/London")!

    public static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, path: Path = .hosting) -> CGImage? {
        configureTextRendering()
        return switch path {
        case .imageRenderer: imageRenderer(view, size: size, scale: scale)
        case .hosting: hosting(view, size: size, scale: scale)
        }
    }

    /// The view with the deterministic snapshot environment, framed to `size`. `TTFormat.locale` is bound to
    /// en_US only for the duration of each render call (task-local), never globally.
    public static func prepared<V: View>(_ view: V, size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.isSnapshot, true)
            .environment(\.locale, locale)
            .environment(\.timeZone, timeZone)
            .environment(\.colorScheme, .dark)
            .transaction { $0.animation = nil }
    }

    /// Pure SwiftUI only (no AppKit-backed controls).
    public static func imageRenderer<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        TTFormat.$locale.withValue(locale) {
            let renderer = ImageRenderer(content: prepared(view, size: size))
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(size)
            renderer.isOpaque = false
            return renderer.cgImage.flatMap(SnapshotImage.normalized)
        }
    }

    /// Offscreen `NSWindow` + `NSHostingView` (draws AppKit-backed controls, text fields, sliders).
    public static func hosting<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        TTFormat.$locale.withValue(locale) { hostingUnscoped(view, size: size, scale: scale) }
    }

    private static func hostingUnscoped<V: View>(_ view: V, size: CGSize, scale: CGFloat) -> CGImage? {
        _ = NSApplication.shared
        let rect = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: prepared(view, size: size))
        host.frame = rect
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // Deterministic passes: layout, then display (no timed run-loop wait).
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()

        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        guard let untagged = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let rep = untagged.retagging(with: .sRGB) else { return nil }
        rep.size = size
        host.cacheDisplay(in: rect, to: rep)
        window.contentView = nil
        window.close()
        guard let image = rep.cgImage else { return nil }
        return SnapshotImage.normalized(image)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func readPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Pixel-level helpers shared by `assertSnapshot` and `telltale-render --compare`.
public enum SnapshotImage {
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// RGBA8 premultiplied, sRGB.
    public static func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }

    static func image(from data: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = data
        return copy.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// Re-encodes into sRGB RGBA8 so goldens are stable regardless of the source color space.
    public static func normalized(_ image: CGImage) -> CGImage? {
        guard let px = pixels(image) else { return nil }
        return self.image(from: px, width: image.width, height: image.height)
    }

    public struct Diff: Sendable {
        /// Fraction of pixels with any channel Δ > threshold.
        public var fraction: Double
        public var sizeMismatch: Bool
        /// Differing pixels red over the golden dimmed to 1/4; nil when no pixel differs (or sizes mismatch).
        public var diffImage: CGImage?
    }

    /// ARCHITECTURE §8: fraction of pixels with any channel Δ > 8/255.
    ///
    /// Test binaries are built `-Onone`, where a per-byte Swift loop over a 1280×860 @2x artboard costs ~3 s on
    /// the main actor. So identical rows and 16-pixel spans are skipped with `memcmp`, only differing spans are
    /// scanned per pixel, and the diff image is composed with Core Graphics only when something differs.
    public static func compare(_ a: CGImage, _ b: CGImage, threshold: UInt8 = 8) -> Diff {
        guard a.width == b.width, a.height == b.height else {
            return Diff(fraction: 1, sizeMismatch: true, diffImage: nil)
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return Diff(fraction: 1, sizeMismatch: false, diffImage: nil) }
        let rowBytes = a.width * 4
        var differingRows: [Int] = []
        var differing = 0
        pa.withUnsafeBufferPointer { x in
            pb.withUnsafeBufferPointer { y in
                guard let xb = x.baseAddress, let yb = y.baseAddress else { return }
                for row in 0..<a.height {
                    let start = row * rowBytes
                    guard memcmp(xb + start, yb + start, rowBytes) != 0 else { continue }
                    let n = differingPixels(xb + start, yb + start, count: a.width, threshold: threshold) { _ in }
                    if n > 0 {
                        differing += n
                        differingRows.append(row)
                    }
                }
            }
        }
        let fraction = Double(differing) / Double(a.width * a.height)
        let overlay = differing == 0 ? nil : diffImage(golden: a, pa: pa, pb: pb, rows: differingRows,
                                                       threshold: threshold)
        return Diff(fraction: fraction, sizeMismatch: false, diffImage: overlay)
    }

    /// Counts pixels in one row whose max channel Δ exceeds `threshold`, reporting each one's index in the row.
    private static func differingPixels(_ x: UnsafePointer<UInt8>, _ y: UnsafePointer<UInt8>, count: Int,
                                        threshold: UInt8, _ mark: (Int) -> Void) -> Int {
        let block = 16 // pixels per memcmp span: most of a differing row is still identical
        var n = 0
        for first in stride(from: 0, to: count, by: block) {
            let end = min(first + block, count)
            guard memcmp(x + first * 4, y + first * 4, (end - first) * 4) != 0 else { continue }
            for p in first..<end {
                var d: UInt8 = 0
                for c in p * 4..<p * 4 + 4 {
                    d = max(d, x[c] > y[c] ? x[c] - y[c] : y[c] - x[c])
                }
                if d > threshold {
                    n += 1
                    mark(p)
                }
            }
        }
        return n
    }

    /// The golden dimmed to 1/4 over opaque black, with the differing pixels of `rows` painted opaque red.
    private static func diffImage(golden: CGImage, pa: [UInt8], pb: [UInt8], rows: [Int], threshold: UInt8) -> CGImage? {
        let w = golden.width, h = golden.height, rowBytes = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(rect)
        ctx.setAlpha(0.25)
        ctx.draw(golden, in: rect)
        pa.withUnsafeBufferPointer { x in
            pb.withUnsafeBufferPointer { y in
                guard let xb = x.baseAddress, let yb = y.baseAddress else { return }
                for row in rows {
                    let start = row * rowBytes
                    _ = differingPixels(xb + start, yb + start, count: w, threshold: threshold) { p in
                        let i = start + p * 4
                        data[i] = 255; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 255
                    }
                }
            }
        }
        return ctx.makeImage()
    }

    /// Crop in pixel coordinates (top-left origin).
    public static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        image.cropping(to: rect.integral)
    }

    /// Side-by-side [reference | ours | 50 % overlay] on `background`.
    public static func comparisonSheet(reference: CGImage, ours: CGImage, background: CGColor) -> CGImage? {
        let w = max(reference.width, ours.width), h = max(reference.height, ours.height)
        let gap = 16
        let total = w * 3 + gap * 2
        guard let ctx = CGContext(data: nil, width: total, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: total, height: h))
        func draw(_ img: CGImage, x: Int, alpha: CGFloat = 1) {
            ctx.setAlpha(alpha)
            ctx.draw(img, in: CGRect(x: x, y: h - img.height, width: img.width, height: img.height))
            ctx.setAlpha(1)
        }
        draw(reference, x: 0)
        draw(ours, x: w + gap)
        draw(reference, x: 2 * (w + gap))
        draw(ours, x: 2 * (w + gap), alpha: 0.5)
        return ctx.makeImage()
    }
}
