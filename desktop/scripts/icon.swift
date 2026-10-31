import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func render(_ size: Int, _ name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: s); transform.concat()
    NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.33, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 35, y: 35, width: 954, height: 954), xRadius: 210, yRadius: 210).fill()
    NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 245, y: 200, width: 535, height: 645), xRadius: 65, yRadius: 65).fill()
    NSColor(calibratedRed: 0.77, green: 0.60, blue: 0.32, alpha: 1).setFill()
    let bookmark = NSBezierPath(); bookmark.move(to: NSPoint(x: 600, y: 845)); bookmark.line(to: NSPoint(x: 680, y: 845)); bookmark.line(to: NSPoint(x: 680, y: 670)); bookmark.line(to: NSPoint(x: 640, y: 710)); bookmark.line(to: NSPoint(x: 600, y: 670)); bookmark.close(); bookmark.fill()
    NSColor(calibratedRed: 0.26, green: 0.42, blue: 0.52, alpha: 1).setFill()
    for (y, width) in [(610, 205), (510, 350), (410, 350), (310, 240)] {
        NSBezierPath(roundedRect: NSRect(x: 335, y: y, width: width, height: 25), xRadius: 12, yRadius: 12).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, "icon_\(size)x\(size).png")
    try render(size * 2, "icon_\(size)x\(size)@2x.png")
}
