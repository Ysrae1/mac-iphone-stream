import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        let scaleFactor = CGFloat(pixels) / 1024
        NSGraphicsContext.current?.cgContext.scaleBy(x: scaleFactor, y: scaleFactor)

        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                                xRadius: 205, yRadius: 205)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.22, blue: 0.32, alpha: 1),
                                  ending: NSColor(srgbRed: 0.10, green: 0.43, blue: 0.46, alpha: 1))!
        gradient.draw(in: tile, angle: 45)

        let monitor = NSBezierPath(roundedRect: NSRect(x: 216, y: 354, width: 480, height: 318),
                                   xRadius: 54, yRadius: 54)
        NSColor.white.withAlphaComponent(0.92).setStroke()
        monitor.lineWidth = 38
        monitor.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 456, y: 352))
        stand.line(to: NSPoint(x: 456, y: 285))
        stand.move(to: NSPoint(x: 378, y: 283))
        stand.line(to: NSPoint(x: 528, y: 283))
        stand.lineCapStyle = .round
        stand.lineWidth = 38
        stand.stroke()

        let phone = NSBezierPath(roundedRect: NSRect(x: 610, y: 265, width: 193, height: 326),
                                 xRadius: 48, yRadius: 48)
        NSColor(srgbRed: 0.09, green: 0.28, blue: 0.34, alpha: 1).setFill()
        phone.fill()
        NSColor(srgbRed: 0.56, green: 0.98, blue: 0.86, alpha: 1).setStroke()
        phone.lineWidth = 35
        phone.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let suffix = scale == 2 ? "@2x" : ""
        try image.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
