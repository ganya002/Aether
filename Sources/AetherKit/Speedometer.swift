import AppKit

/// A round gauge, open at the bottom like a speedometer, with the percent in the hub.
final class Speedometer: NSView {
    var fraction: Double = 0 {
        didSet {
            if !fraction.isFinite || fraction < 0 || fraction > 1 {
                fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
                return
            }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.38
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        let face = Self.faceRect(in: bounds)
        layer?.shadowPath = CGPath(ellipseIn: face, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let face = Self.faceRect(in: bounds)
        let center = CGPoint(x: face.midX, y: face.midY)
        let side = face.width
        let arcRadius = side * 0.355
        let start = CGFloat(216)
        let sweep = CGFloat(252)

        let faceColor = NSColor(srgbRed: 0.06, green: 0.05, blue: 0.08, alpha: 0.94)
        faceColor.setFill()
        NSBezierPath(ovalIn: face).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let rim = NSBezierPath(ovalIn: face.insetBy(dx: 0.6, dy: 0.6))
        rim.lineWidth = 1
        rim.stroke()

        let tickRadius = arcRadius + side * 0.055
        for index in 0...20 {
            let major = index.isMultiple(of: 4)
            let angle = (start - sweep * CGFloat(index) / 20) * .pi / 180
            let outer = tickRadius
            let inner = tickRadius - (major ? side * 0.045 : side * 0.026)
            let mark = NSBezierPath()
            mark.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            mark.line(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            mark.lineWidth = major ? 1.6 : 1
            mark.lineCapStyle = .round
            NSColor.white.withAlphaComponent(major ? 0.72 : 0.32).setStroke()
            mark.stroke()
        }

        let track = arc(center: center, radius: arcRadius, start: start, sweep: sweep)
        track.lineWidth = side * 0.045
        track.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.14).setStroke()
        track.stroke()

        if fraction > 0.001 {
            let progress = arc(center: center, radius: arcRadius, start: start, sweep: sweep * CGFloat(fraction))
            progress.lineWidth = side * 0.045
            progress.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.94).setStroke()
            progress.stroke()
        }

        let needleAngle = (start - sweep * CGFloat(fraction)) * .pi / 180
        let hubRadius = side * 0.17
        let needle = NSBezierPath()
        needle.move(to: CGPoint(x: center.x + cos(needleAngle) * hubRadius, y: center.y + sin(needleAngle) * hubRadius))
        needle.line(to: CGPoint(x: center.x + cos(needleAngle) * arcRadius, y: center.y + sin(needleAngle) * arcRadius))
        needle.lineWidth = 2.4
        needle.lineCapStyle = .round
        NSColor.white.setStroke()
        needle.stroke()

        faceColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)).fill()

        let percent = "\(Int((fraction * 100).rounded()))%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: side * 0.145, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        ]
        let textSize = percent.size(withAttributes: attributes)
        let textRect = NSRect(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2 - 1,
            width: textSize.width,
            height: textSize.height
        )
        percent.draw(in: textRect, withAttributes: attributes)
    }

    private static func faceRect(in bounds: NSRect) -> NSRect {
        let side = min(bounds.width, bounds.height) * 0.9
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private func arc(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: start,
            endAngle: start - sweep,
            clockwise: true
        )
        return path
    }
}

final class UpdateVeil: NSView {
    let gauge = Speedometer(frame: NSRect(x: 0, y: 0, width: 188, height: 188))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(gauge)
        positionGauge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        positionGauge()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        positionGauge()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func positionGauge() {
        let side: CGFloat = 188
        gauge.frame = NSRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }
}
