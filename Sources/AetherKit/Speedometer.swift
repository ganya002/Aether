import AppKit

/// A round gauge, open at the bottom like a speedometer, with the percent in the hub.
final class Speedometer: NSView {
    /// Where the needle is settling. Drawing uses the sprung value, so it hops instead of snapping.
    private var goal: Double = 0
    private var shown: Double = 0
    private var velocity: Double = 0
    private var ticker: Timer?

    var fraction: Double {
        get { goal }
        set { setFraction(newValue) }
    }

    func setFraction(_ value: Double) {
        let clamped = min(1, max(0, value.isFinite ? value : 0))
        let stepped = (clamped * 100).rounded() / 100
        guard abs(stepped - goal) > 0.004 else { return }
        goal = stepped
        if ticker == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.advanceNeedle()
            }
            ticker = timer
            RunLoop.main.add(timer, forMode: .common)
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

    private func advanceNeedle() {
        let dt = 1.0 / 60.0
        let stiffness = 260.0
        let damping = 16.0
        velocity += ((goal - shown) * stiffness - velocity * damping) * dt
        shown += velocity * dt
        if abs(goal - shown) < 0.0015, abs(velocity) < 0.015 {
            shown = goal
            velocity = 0
            ticker?.invalidate()
            ticker = nil
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        ticker?.invalidate()
        ticker = nil
    }

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
        let displayed = min(1, max(0, shown))

        let faceColor = NSColor.white.withAlphaComponent(0.1)
        faceColor.setFill()
        NSBezierPath(ovalIn: face).fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
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

        if displayed > 0.001 {
            let progress = arc(center: center, radius: arcRadius, start: start, sweep: sweep * CGFloat(displayed))
            progress.lineWidth = side * 0.045
            progress.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.94).setStroke()
            progress.stroke()
        }

        let needleAngle = (start - sweep * CGFloat(displayed)) * .pi / 180
        let hubRadius = side * 0.17
        let needle = NSBezierPath()
        needle.move(to: CGPoint(x: center.x + cos(needleAngle) * hubRadius, y: center.y + sin(needleAngle) * hubRadius))
        needle.line(to: CGPoint(x: center.x + cos(needleAngle) * arcRadius, y: center.y + sin(needleAngle) * arcRadius))
        needle.lineWidth = 2.4
        needle.lineCapStyle = .round
        NSColor.white.setStroke()
        needle.stroke()

        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)).fill()

        let percent = "\(Int((displayed * 100).rounded()))%"
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
    var onInstall: (() -> Void)?
    let gauge = Speedometer(frame: NSRect(x: 0, y: 0, width: 188, height: 188))
    private let cluster = NSView()
    private let install = NSButton()
    private var revealed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cluster.wantsLayer = true
        install.title = "Install now"
        install.bezelStyle = .rounded
        install.font = .systemFont(ofSize: 13, weight: .semibold)
        install.target = self
        install.action = #selector(installPressed)
        install.isEnabled = false
        cluster.addSubview(gauge)
        cluster.addSubview(install)
        addSubview(cluster)
        positionGauge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func reveal() {
        guard !revealed else { return }
        revealed = true
        layoutSubtreeIfNeeded()
        cluster.alphaValue = 0
        cluster.layer?.transform = CATransform3DIdentity
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.78
        spring.toValue = 1
        spring.mass = 0.7
        spring.stiffness = 220
        spring.damping = 15
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        cluster.layer?.add(spring, forKey: "reveal")
        let settle = spring.settlingDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            self?.cluster.layer?.removeAnimation(forKey: "reveal")
            self?.cluster.layer?.transform = CATransform3DIdentity
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = Motion.ease()
            cluster.animator().alphaValue = 1
        }
    }

    func setInstallEnabled(_ enabled: Bool) {
        install.isEnabled = enabled
        install.alphaValue = enabled ? 1 : 0.45
    }

    override func layout() {
        super.layout()
        positionGauge()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        positionGauge()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard install.isEnabled else { return nil }
        let local = convert(point, from: superview)
        let inCluster = cluster.convert(local, from: self)
        guard install.frame.contains(inCluster) else { return nil }
        return install
    }

    @objc private func installPressed() {
        onInstall?()
    }

    private func positionGauge() {
        let gaugeSide: CGFloat = 188
        let button = NSSize(width: 132, height: 28)
        let gap: CGFloat = 10
        let height = gaugeSide + gap + button.height
        cluster.frame = NSRect(
            x: (bounds.width - gaugeSide) / 2,
            y: (bounds.height - height) / 2,
            width: gaugeSide,
            height: height
        )
        gauge.frame = NSRect(x: 0, y: button.height + gap, width: gaugeSide, height: gaugeSide)
        install.frame = NSRect(x: (gaugeSide - button.width) / 2, y: 0, width: button.width, height: button.height)
    }
}
