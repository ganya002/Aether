import AppKit

/// A round gauge, open at the bottom like a speedometer, with the percent in the hub.
final class Speedometer: NSView {
    /// Where the needle is settling. Drawing uses the sprung value, so it hops instead of snapping.
    private var goal: Double = 0
    private var shown: Double = 0
    private var velocity: Double = 0
    private var ticker: Timer?

    /// The tiny gauge in the update toast is too small for a readable percent.
    var showsPercent = true {
        didSet { needsDisplay = true }
    }

    var fraction: Double {
        get { goal }
        set { setFraction(newValue) }
    }

    func setFraction(_ value: Double) {
        let clamped = min(1, max(0, value.isFinite ? value : 0))
        let stepped = (clamped * 100).rounded() / 100
        guard abs(stepped - goal) > 0.004 else { return }
        goal = stepped
        NSAccessibility.post(element: self, notification: .valueChanged)
        if Motion.reduced {
            ticker?.invalidate()
            ticker = nil
            shown = goal
            velocity = 0
            needsDisplay = true
            return
        }
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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? { "Download progress" }
    override func accessibilityValue() -> Any? { NSNumber(value: Int((goal * 100).rounded())) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }

    /// White on dark glass, near-black on light glass, following the text tone setting.
    @MainActor static var ink: NSColor {
        AppModel.shared.settings.text.effective == .light ? .white : NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1)
    }

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
        let ink = Self.ink

        let faceColor = ink.withAlphaComponent(0.1)
        faceColor.setFill()
        NSBezierPath(ovalIn: face).fill()
        ink.withAlphaComponent(0.28).setStroke()
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
            ink.withAlphaComponent(major ? 0.72 : 0.32).setStroke()
            mark.stroke()
        }

        let track = arc(center: center, radius: arcRadius, start: start, sweep: sweep)
        track.lineWidth = side * 0.045
        track.lineCapStyle = .round
        ink.withAlphaComponent(0.14).setStroke()
        track.stroke()

        if displayed > 0.001 {
            let progress = arc(center: center, radius: arcRadius, start: start, sweep: sweep * CGFloat(displayed))
            progress.lineWidth = side * 0.045
            progress.lineCapStyle = .round
            ink.withAlphaComponent(0.94).setStroke()
            progress.stroke()
        }

        let needleAngle = (start - sweep * CGFloat(displayed)) * .pi / 180
        let hubRadius = side * 0.17
        let needle = NSBezierPath()
        needle.move(to: CGPoint(x: center.x + cos(needleAngle) * hubRadius, y: center.y + sin(needleAngle) * hubRadius))
        needle.line(to: CGPoint(x: center.x + cos(needleAngle) * arcRadius, y: center.y + sin(needleAngle) * arcRadius))
        needle.lineWidth = 2.4
        needle.lineCapStyle = .round
        ink.setStroke()
        needle.stroke()

        ink.withAlphaComponent(0.14).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)).fill()

        guard showsPercent else { return }
        let percent = "\(Int((displayed * 100).rounded()))%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: side * 0.145, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink.withAlphaComponent(0.96),
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

/// The update toast: a small glass card at the bottom-right of the window.
/// The view spans the canvas so it can follow resizes, but only the card takes clicks.
final class UpdateVeil: NSView {
    var onInstall: (() -> Void)?
    var onLater: (() -> Void)?
    let gauge = Speedometer(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    private let glass = NSGlassEffectView()
    private let card = NSView()
    private let label = NSTextField(labelWithString: "")
    private let later = NSButton()
    private let install = NSButton()
    private var showsGauge = false
    private var revealed = false

    private static let margin: CGFloat = 16
    private static let height: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gauge.showsPercent = false
        gauge.layer?.shadowOpacity = 0
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = Speedometer.ink.withAlphaComponent(0.95)
        label.lineBreakMode = .byTruncatingTail
        configure(later, title: "Later", action: #selector(laterPressed))
        configure(install, title: "Restart to Update", action: #selector(installPressed))
        card.addSubview(gauge)
        card.addSubview(label)
        card.addSubview(later)
        card.addSubview(install)
        glass.style = .regular
        glass.cornerRadius = 14
        glass.contentView = card
        glass.wantsLayer = true
        addSubview(glass)
        showReady()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        // Clicking the toast must not pull focus out of the terminal.
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
    }

    func showDownloading() {
        showsGauge = true
        gauge.isHidden = false
        label.textColor = Speedometer.ink.withAlphaComponent(0.95)
        label.stringValue = "Downloading Aether update…"
        install.isEnabled = false
        install.isHidden = true
        later.isEnabled = true
        positionCard()
    }

    func showReady() {
        showsGauge = false
        gauge.isHidden = true
        label.textColor = Speedometer.ink.withAlphaComponent(0.95)
        label.stringValue = "Aether update ready"
        install.isHidden = false
        install.isEnabled = true
        later.isEnabled = true
        positionCard()
    }

    func showMessage(_ text: String) {
        label.textColor = Speedometer.ink.withAlphaComponent(0.95)
        label.stringValue = text
        positionCard()
    }

    func setRestarting(_ restarting: Bool) {
        install.isEnabled = !restarting
        later.isEnabled = !restarting
    }

    func reveal() {
        guard !revealed else { return }
        revealed = true
        layoutSubtreeIfNeeded()
        glass.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reveal
            context.timingFunction = Motion.ease()
            glass.animator().alphaValue = 1
        }
    }

    override func layout() {
        super.layout()
        positionCard()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        positionCard()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard glass.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    @objc private func installPressed() {
        onInstall?()
    }

    @objc private func laterPressed() {
        onLater?()
    }

    private func positionCard() {
        let height = Self.height
        let pad: CGFloat = 14
        let gap: CGFloat = 8
        let gaugeSide: CGFloat = 30
        label.sizeToFit()
        later.sizeToFit()
        install.sizeToFit()
        let maxWidth = max(160, bounds.width - Self.margin * 2)
        var buttons = later.frame.width
        if !install.isHidden { buttons += gap + install.frame.width }
        let lead = showsGauge ? gaugeSide + gap : 0
        let labelWidth = min(label.frame.width, max(60, maxWidth - pad * 2 - lead - buttons - 12))
        let width = pad + lead + labelWidth + 12 + buttons + pad - 4
        let frame = NSRect(
            x: bounds.maxX - width - Self.margin,
            y: Self.margin,
            width: width,
            height: height
        )
        glass.frame = frame
        card.frame = glass.bounds
        var x = pad
        if showsGauge {
            gauge.frame = NSRect(x: x - 4, y: (height - gaugeSide) / 2, width: gaugeSide, height: gaugeSide)
            x += lead
        }
        label.frame = NSRect(x: x, y: (height - label.frame.height) / 2, width: labelWidth, height: label.frame.height)
        x += labelWidth + 12
        later.frame.origin = NSPoint(x: x, y: (height - later.frame.height) / 2)
        x += later.frame.width + gap
        install.frame.origin = NSPoint(x: x, y: (height - install.frame.height) / 2)
    }
}
