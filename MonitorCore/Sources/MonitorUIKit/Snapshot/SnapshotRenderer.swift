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
        public var diffImage: CGImage?
    }

    /// ARCHITECTURE §8: fraction of pixels with any channel Δ > 8/255.
    public static func compare(_ a: CGImage, _ b: CGImage, threshold: UInt8 = 8) -> Diff {
        guard a.width == b.width, a.height == b.height else {
            return Diff(fraction: 1, sizeMismatch: true, diffImage: nil)
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return Diff(fraction: 1, sizeMismatch: false, diffImage: nil) }
        var out = [UInt8](repeating: 0, count: pa.count)
        var differing = 0
        var i = 0
        while i < pa.count {
            var d: UInt8 = 0
            for c in 0..<4 {
                let x = pa[i + c], y = pb[i + c]
                d = max(d, x > y ? x - y : y - x)
            }
            if d > threshold {
                differing += 1
                out[i] = 255; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 255
            } else {
                // Dimmed golden for context.
                out[i] = pa[i] / 4; out[i + 1] = pa[i + 1] / 4; out[i + 2] = pa[i + 2] / 4; out[i + 3] = 255
            }
            i += 4
        }
        let fraction = Double(differing) / Double(a.width * a.height)
        return Diff(fraction: fraction, sizeMismatch: false, diffImage: image(from: out, width: a.width, height: a.height))
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
