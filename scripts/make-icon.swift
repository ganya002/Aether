import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let files: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Apple's icon shape: a squircle with continuous corners, not a rounded rectangle.
func squircle(_ rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    let steps = 360
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        step == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

/// The mark: a prompt chevron and a cursor, drawn rather than typed, so it sits optically centered.
func drawMark(in body: NSRect, scale: CGFloat, small: Bool) {
    let unit = body.width / 824
    let weight = (small ? 120 : 96) * unit
    let left = body.minX + (small ? 200 : 214) * unit
    let tip = body.minX + (small ? 420 : 400) * unit
    let mid = body.midY + 24 * unit
    let reach = (small ? 190 : 170) * unit

    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: left, y: mid + reach))
    chevron.line(to: NSPoint(x: tip, y: mid))
    chevron.line(to: NSPoint(x: left, y: mid - reach))
    chevron.lineWidth = weight
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round

    let cursorHeight = (small ? 110 : 84) * unit
    let cursor = NSBezierPath(
        roundedRect: NSRect(x: tip + (small ? 60 : 80) * unit, y: mid - reach - cursorHeight / 2,
                            width: (small ? 190 : 200) * unit, height: cursorHeight),
        xRadius: cursorHeight / 2, yRadius: cursorHeight / 2
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = srgb(0x05070F, 0.55)
    shadow.shadowBlurRadius = 28 * unit
    shadow.shadowOffset = NSSize(width: 0, height: -14 * unit)
    shadow.set()
    srgb(0xF4F6FB).setStroke()
    chevron.stroke()
    // The cursor carries the aether glow: a cool cyan, a touch brighter than the chevron is white.
    srgb(0x7DE3F4).setFill()
    cursor.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(size: Int) {
    let canvas = CGFloat(size)
    let scale = canvas / 1024
    let small = size <= 32
    // Apple's grid: an 824 body centered on a 1024 canvas, a little low to leave room for the shadow.
    let body = NSRect(x: 100 * scale, y: 112 * scale, width: 824 * scale, height: 824 * scale)
    let shape = squircle(body)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.35)
    drop.shadowBlurRadius = 24 * scale
    drop.shadowOffset = NSSize(width: 0, height: -10 * scale)
    drop.set()
    srgb(0x0B1020).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [srgb(0x1C2550), srgb(0x0B1022)], atLocations: [0, 1], colorSpace: .sRGB)?
        .draw(in: body, angle: -90)
    if !small {
        // Two soft lights, violet above and cyan below, like light through thin air.
        NSGradient(colors: [srgb(0x8B6CF6, 0.75), srgb(0x8B6CF6, 0)], atLocations: [0, 1], colorSpace: .sRGB)?
            .draw(fromCenter: NSPoint(x: body.minX + body.width * 0.22, y: body.maxY - body.height * 0.12), radius: 0,
                  toCenter: NSPoint(x: body.minX + body.width * 0.22, y: body.maxY - body.height * 0.12), radius: body.width * 0.72,
                  options: [])
        NSGradient(colors: [srgb(0x22C3E6, 0.42), srgb(0x22C3E6, 0)], atLocations: [0, 1], colorSpace: .sRGB)?
            .draw(fromCenter: NSPoint(x: body.maxX - body.width * 0.1, y: body.minY + body.height * 0.18), radius: 0,
                  toCenter: NSPoint(x: body.maxX - body.width * 0.1, y: body.minY + body.height * 0.18), radius: body.width * 0.65,
                  options: [])
    }
    drawMark(in: body, scale: scale, small: small)
    NSGraphicsContext.restoreGraphicsState()

    // A hairline of light on the top edge, fading out by the middle, and a darker rim below.
    NSGraphicsContext.saveGraphicsState()
    let ring = NSBezierPath()
    ring.append(shape)
    ring.append(squircle(body.insetBy(dx: max(1, 5 * scale), dy: max(1, 5 * scale))))
    ring.windingRule = .evenOdd
    ring.addClip()
    NSGradient(colors: [srgb(0xFFFFFF, 0.38), srgb(0xFFFFFF, 0.04), srgb(0x000000, 0.25)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)?
        .draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

for (size, name) in files {
    // Draw into a bitmap with an explicit pixel size. lockFocus renders at the screen's
    // backing scale, so on a Retina Mac every PNG came out twice as large as its name says.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Could not draw \(size)\n", stderr)
        exit(1)
    }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(size: size)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Could not draw \(size)\n", stderr)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
