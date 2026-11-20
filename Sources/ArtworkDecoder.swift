import Foundation
import ImageIO
import CoreGraphics

/// Decodes now-playing artwork received from the helper. Pure and nonisolated: meant to run off the
/// main actor. Rejects oversized payloads and images larger than `maxPixels` before decoding them.
enum ArtworkDecoder {
    static let maxBytes = 2 << 20      // 2 MB of image data
    static let maxPixels = 2048

    nonisolated static func decode(base64: String) -> CGImage? {
        // base64 expands data by 4/3
        guard base64.utf8.count <= maxBytes * 4 / 3 + 8,
              let data = Data(base64Encoded: base64), data.count <= maxBytes,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxPixels, h <= maxPixels else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
