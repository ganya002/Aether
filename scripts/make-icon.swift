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

for (size, name) in files {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let scale = CGFloat(size) / 1024
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 80 * scale, dy: 80 * scale), xRadius: 220 * scale, yRadius: 220 * scale)
    NSColor(srgbRed: 0.93, green: 0.96, blue: 0.98, alpha: 0.22).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.85).setStroke()
    path.lineWidth = 18 * scale
    path.stroke()

    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: 220 * scale, y: 760 * scale))
    gloss.curve(
        to: NSPoint(x: 780 * scale, y: 700 * scale),
        controlPoint1: NSPoint(x: 360 * scale, y: 900 * scale),
        controlPoint2: NSPoint(x: 620 * scale, y: 860 * scale)
    )
    NSColor.white.withAlphaComponent(0.9).setStroke()
    gloss.lineWidth = 28 * scale
    gloss.lineCapStyle = .round
    gloss.stroke()

    let prompt = ">" as NSString
    let font = NSFont.monospacedSystemFont(ofSize: 420 * scale, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let textSize = prompt.size(withAttributes: attributes)
    prompt.draw(
        at: NSPoint(x: (CGFloat(size) - textSize.width) / 2 - 20 * scale, y: (CGFloat(size) - textSize.height) / 2 - 10 * scale),
        withAttributes: attributes
    )
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Could not draw \(size)\n", stderr)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
