import CoreGraphics
import Foundation
import ImageIO

struct EncodedImage {
    var png: Data
    var thumbnail: Data
    var width: Int
    var height: Int
}

enum ImageEncoding {
    private static let pngType = "public.png"

    /// Re-encodes any ImageIO-readable bytes as PNG and renders a thumbnail whose longest side is
    /// `thumbnailPixels`. nil when the bytes are not an image.
    static func encode(_ data: Data, thumbnailPixels: Int) -> EncodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = pngData(image)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let thumbPNG = pngData(thumb)
        else { return nil }
        return EncodedImage(png: png, thumbnail: thumbPNG, width: image.width, height: image.height)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, pngType as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
