import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct MediaProcessorTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }
    static func fixture(_ width: Int, _ height: Int, type: UTType = .png, frames: Int = 1) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, type.identifier as CFString, frames, nil)!
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        precondition(CGImageDestinationFinalize(destination))
        return result as Data
    }
    static func main() throws {
        let large = fixture(3000, 1500)
        let result = try MediaProcessor.prepare(large, filename: "screenshot.png")
        expect(result.width == 2400 && result.height == 1200, "Large screenshot resized without changing aspect ratio")
        expect(result.filename == "screenshot.png", "Screenshot remains PNG")
        expect(result.data.count < large.count, "Large screenshot is smaller")
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(result.data as CFData, nil)!, 0, nil)!
        expect([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(decoded.alphaInfo), "Transparency survives resizing")
        let unchanged = try MediaProcessor.prepare(large, filename: "screenshot.png", optimize: false)
        expect(unchanged.data == large && unchanged.width == 3000, "Original option preserves exact bytes")
        let jpeg = try MediaProcessor.prepare(fixture(2600, 1300, type: .jpeg), filename: "photo.png")
        expect(jpeg.filename == "photo.jpg" && jpeg.width == 2400, "Detected format determines output extension")
        let tiff = try MediaProcessor.prepare(fixture(20, 30, type: .tiff), filename: "Clipboard.tiff", optimize: false)
        expect(tiff.filename == "Clipboard.png" && tiff.width == 20 && tiff.height == 30, "Clipboard TIFF converts to web-safe PNG")
        let animated = fixture(20, 30, type: .gif, frames: 2)
        let animation = try MediaProcessor.prepare(animated, filename: "animated.gif")
        expect(animation.data == animated && animation.note.contains("Animation"), "Animation is preserved byte-for-byte")
        do { _ = try MediaProcessor.prepare(Data("not an image".utf8), filename: "bad.png"); preconditionFailure("Invalid data accepted") } catch { assertions += 1 }
        do { _ = try MediaProcessor.prepare(Data(repeating: 0, count: MediaProcessor.maxBytes + 1), filename: "huge.png"); preconditionFailure("Oversize data accepted") } catch { assertions += 1 }
        print("MediaProcessor: \(assertions) assertions passed")
    }
}
