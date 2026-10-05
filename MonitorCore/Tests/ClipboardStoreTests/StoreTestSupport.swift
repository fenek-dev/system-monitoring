import ClipboardCore
import CoreGraphics
import Foundation
import ImageIO
@testable import ClipboardStore

enum T {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs `body` with a fresh directory and removes it afterwards.
    static func withDirectory<R>(_ body: (URL) async throws -> R) async throws -> R {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    static func text(_ value: String, app: String? = nil) -> ClipCapture {
        ClipCapture(content: .text(value), source: ClipSource(bundleID: app.map { "com.test.\($0)" }, name: app))
    }

    static func image(_ data: Data) -> ClipCapture { ClipCapture(content: .image(data)) }

    /// A PNG filled with one colour; `red` varies the bytes (and so the hash) between images.
    static func png(width: Int = 40, height: Int = 30, red: CGFloat = 0) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: 0.4, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    static func fileNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
