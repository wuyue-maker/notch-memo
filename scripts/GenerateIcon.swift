import AppKit
import Foundation

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1), ending: NSColor(calibratedWhite: 0.08, alpha: 1))!
            .draw(in: background, angle: -60)
        let paper = NSBezierPath(roundedRect: NSRect(x: 242, y: 224, width: 540, height: 586), xRadius: 58, yRadius: 58)
        NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.89, alpha: 1).setFill()
        paper.fill()
        let notch = NSBezierPath(roundedRect: NSRect(x: 409, y: 749, width: 206, height: 121), xRadius: 34, yRadius: 34)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); notch.fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 346, y: 520)); check.line(to: NSPoint(x: 430, y: 433)); check.line(to: NSPoint(x: 641, y: 646))
        check.lineWidth = 51; check.lineCapStyle = .round; check.lineJoinStyle = .round
        NSColor(calibratedRed: 0.78, green: 0.35, blue: 0.20, alpha: 1).setStroke(); check.stroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 351, y: 341)); line.line(to: NSPoint(x: 639, y: 341)); line.lineWidth = 19; line.lineCapStyle = .round
        NSColor(calibratedRed: 0.75, green: 0.72, blue: 0.63, alpha: 1).setStroke(); line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
