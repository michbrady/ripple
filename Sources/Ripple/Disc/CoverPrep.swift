import Foundation
import ImageIO
import RippleKit
import UniformTypeIdentifiers

/// Gets a cover picture ready to embed: JPEG or PNG, at most 1,200 pixels on a side.
/// Other formats (TIFF, HEIC, GIF) and larger pictures become a JPEG of up to 1,000 pixels.
nonisolated enum CoverPrep {
    static let keepUpTo = 1_200
    static let resizeTo = 1_000

    /// Returns nil when the bytes are not an image.
    static func prepared(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let type = CGImageSourceGetType(source) as String?
        let embeddable = type == UTType.jpeg.identifier || type == UTType.png.identifier
        if embeddable, max(width, height) <= keepUpTo { return data }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: resizeTo,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
