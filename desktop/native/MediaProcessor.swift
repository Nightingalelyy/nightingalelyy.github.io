import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedImage {
    let data: Data
    let filename: String
    let width: Int
    let height: Int
    let originalBytes: Int
    let note: String
}

enum MediaProcessor {
    static let maxBytes = 20 * 1024 * 1024
    static func prepare(_ data: Data, filename: String, optimize: Bool = true) throws -> PreparedImage {
        func failure(_ message: String) -> NSError { NSError(domain: "WriterMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard !data.isEmpty, data.count <= maxBytes else { throw failure("Choose an image smaller than 20 MB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 80_000_000 else {
            throw failure("This image cannot be read, or is larger than 80 megapixels.")
        }
        let extensions = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpg", UTType.gif.identifier: "gif", UTType.webP.identifier: "webp", UTType.tiff.identifier: "tiff"]
        guard let ext = extensions[type] else { throw failure("Choose a PNG, JPEG, GIF, WebP, or TIFF image.") }
        let base = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let stem = base.isEmpty ? "pasted-image" : base
        func original(_ note: String = "Original image kept") -> PreparedImage {
            PreparedImage(data: data, filename: stem + "." + ext, width: width, height: height, originalBytes: data.count, note: note)
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 {
            guard ext != "tiff" else { throw failure("Choose a single-page image instead of a multi-page TIFF.") }
            return original("Animation kept unchanged")
        }
        if !optimize && ext != "tiff" { return original() }
        let maxDimension = optimize ? min(2400, max(width, height)) : max(width, height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw failure("This image could not be prepared for the website.") }
        // Screenshots and transparent artwork stay lossless; only JPEG photos use lossy compression.
        let outputType = ext == "jpg" ? UTType.jpeg : UTType.png
        let outputExt = outputType == .jpeg ? "jpg" : "png"
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, outputType.identifier as CFString, 1, nil) else { throw failure("Image compression is unavailable.") }
        let outputOptions: [CFString: Any] = outputType == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.86] : [:]
        CGImageDestinationAddImage(destination, image, outputOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("This image could not be saved.") }
        let resized = max(width, height) > maxDimension
        if ext != "tiff" && !resized && buffer.length >= data.count { return original("Already optimized") }
        guard buffer.length <= maxBytes else { throw failure("The prepared image is larger than 20 MB. Choose a smaller image.") }
        return PreparedImage(data: buffer as Data, filename: stem + "." + outputExt, width: image.width, height: image.height,
                             originalBytes: data.count, note: resized ? "Resized to fit 2400 px" : (ext == "tiff" ? "Converted to PNG" : "Compressed"))
    }
}
