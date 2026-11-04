import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PhotoInfo: Sendable {
    public var width: Int
    public var height: Int
    public var format: String
}

public enum PhotoEncoderError: LocalizedError {
    case unreadable, writeFailed, verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "macOS cannot read this image."
        case .writeFailed: return "Writing the HEIC file failed."
        case .verifyFailed(let m): return "The new file did not check out: \(m)"
        }
    }
}

/// Re-encodes a photo to HEIC at the same resolution, keeping its metadata
/// (capture date, location, orientation, colour profile).
public enum PhotoEncoder {
    /// Formats worth converting. HEIC and RAW are left alone: one is already
    /// efficient, the other is a source file photographers keep on purpose.
    public static let convertible: Set<String> = ["png", "tif", "tiff", "jpg", "jpeg", "bmp"]

    public static let defaultQuality = 0.8

    public static func probe(_ url: URL) -> PhotoInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return PhotoInfo(width: w, height: h, format: url.pathExtension.lowercased())
    }

    /// Expected HEIC size as a share of the original, by source format. A
    /// PNG screenshot shrinks far more than a JPEG that is already lossy.
    public static func estimatedRatio(format: String) -> Double {
        switch format {
        case "png": return 0.14
        case "tif", "tiff", "bmp": return 0.08
        default: return 0.5
        }
    }

    public static func encode(source: URL, output: URL, quality: Double = defaultQuality) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw PhotoEncoderError.unreadable }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw PhotoEncoderError.writeFailed
        }
        // AddImageFromSource carries EXIF, GPS, orientation and the colour
        // profile across untouched.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(dest, src, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoEncoderError.writeFailed }
    }

    public static func verify(original: URL, converted: URL) throws {
        guard let a = probe(original), let b = probe(converted) else { throw PhotoEncoderError.verifyFailed("unreadable") }
        guard a.width == b.width, a.height == b.height else { throw PhotoEncoderError.verifyFailed("size changed") }
        // A logo or screenshot with transparency must stay transparent.
        if hasAlpha(original), !hasAlpha(converted) { throw PhotoEncoderError.verifyFailed("transparency was lost") }
    }

    /// Whether the image carries a transparent layer.
    public static func hasAlpha(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        if let flag = props[kCGImagePropertyHasAlpha] as? Bool { return flag }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }
}
