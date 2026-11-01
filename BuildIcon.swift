// Build the application icon from the original Boschert Technologies artwork.
import AppKit

guard CommandLine.arguments.count == 3,
      let mark = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: BuildIcon company-mark.png output.iconset")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let edge = CGFloat(pixels)
        let inset = edge * 0.07
        let background = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: edge - 2 * inset, height: edge - 2 * inset),
                                     xRadius: edge * 0.19, yRadius: edge * 0.19)
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
        background.fill()
        NSColor(calibratedWhite: 0.84, alpha: 1).setStroke()
        background.lineWidth = max(0.7, edge * 0.002)
        background.stroke()
        let height = edge * 0.61
        let width = height * mark.size.width / mark.size.height
        mark.draw(in: NSRect(x: (edge - width) / 2, y: (edge - height) / 2, width: width, height: height),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
