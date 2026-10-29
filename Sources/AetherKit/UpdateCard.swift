import AppKit
import CoreImage
import QuartzCore

/// Every state the update card and Settings can show. UpdateCenter and the demo drive both through this.
enum UpdateStage: Equatable {
    case checking
    case upToDate
    case downloading(ReleaseFeed.Offer, DownloadProgress)
    case verifying(ReleaseFeed.Offer)
    case ready(ReleaseFeed.Offer)
    case restarting(ReleaseFeed.Offer)
    case failed(String)
    /// The end of `AETHER_UPDATE_DEMO`: nothing was installed, and the card says so.
    case demoFinished

    var offer: ReleaseFeed.Offer? {
        switch self {
        case .downloading(let offer, _), .verifying(let offer), .ready(let offer), .restarting(let offer): offer
        default: nil
        }
    }

    /// One line for Settings and VoiceOver.
    @MainActor var summary: String {
        switch self {
        case .checking: "Checking for updates…"
        case .upToDate:
            // A time, so an old answer never reads as a fresh one.
            "Up to date · checked \((UpdateCenter.shared.checkedAt ?? Date()).formatted(date: .omitted, time: .shortened))"
        case .downloading(_, let progress): "Downloading update · \(Int((progress.fraction * 100).rounded()))%"
        case .verifying: "Verifying the update…"
        case .ready(let offer): "\(UpdateCard.name(of: offer)) is ready to install"
        case .restarting: "Restarting…"
        case .failed(let message): message
        case .demoFinished: "Demo finished. Nothing was installed."
        }
    }

    /// How long a passing stage stays before it dissolves. Errors and choices wait for the person.
    var linger: TimeInterval? {
        switch self {
        case .upToDate: 2.5
        case .demoFinished: 4
        default: nil
        }
    }

    /// Stages of the same kind update in place. A new kind crossfades the card.
    fileprivate var kind: Int {
        switch self {
        case .checking: 0
        case .upToDate: 1
        case .downloading: 2
        case .verifying: 3
        case .ready: 4
        case .restarting: 5
        case .failed: 6
        case .demoFinished: 7
        }
    }
}

struct DownloadProgress: Equatable {
    var written: Int64 = 0
    var total: Int64 = 0
    /// Smoothed, so the time left doesn't jitter with every packet.
    var bytesPerSecond: Double = 0
    /// Restart to Update was pressed early; Aether restarts when the download is verified.
    var thenRestart = false
    private var sampledAt: TimeInterval?
    private var sampledBytes: Int64 = 0

    var fraction: Double {
        total > 0 ? min(1, max(0, Double(written) / Double(total))) : 0
    }

    var secondsLeft: Double? {
        guard bytesPerSecond > 1, total > written else { return nil }
        return Double(total - written) / bytesPerSecond
    }

    /// Speed is sampled at most four times a second; a moving average blends the samples.
    mutating func advance(written: Int64, total: Int64, at time: TimeInterval) {
        self.written = written
        self.total = total
        guard let last = sampledAt else {
            sampledAt = time
            sampledBytes = written
            return
        }
        guard time - last >= 0.25 else { return }
        let instant = Double(max(0, written - sampledBytes)) / (time - last)
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.75 + instant * 0.25
        sampledAt = time
        sampledBytes = written
    }

    /// "4.2 MB of 12 MB · 2.1 MB/s · 4 sec left". Speed and time appear once there is a rate.
    var detail: String {
        guard total > 0 else { return "Starting download…" }
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        var parts = ["\(bytes.string(fromByteCount: written)) of \(bytes.string(fromByteCount: total))"]
        if bytesPerSecond > 1 {
            parts.append("\(bytes.string(fromByteCount: Int64(bytesPerSecond)))/s")
        }
        if let left = secondsLeft {
            let time = DateComponentsFormatter()
            time.unitsStyle = .short
            time.maximumUnitCount = 1
            time.allowedUnits = left < 60 ? [.second] : [.minute]
            if let text = time.string(from: max(1, left.rounded())) { parts.append("\(text) left") }
        }
        return parts.joined(separator: " · ")
    }
}

/// Release notes are light Markdown: headings, bullets, **bold**, *italic*, `code` and links.
enum ReleaseNotes {
    /// The lines worth reading. Release metadata (`aether-build: …`) and the bare "Update <commit>" line are left out.
    static func lines(_ notes: String) -> [String] {
        var kept = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            if line.lowercased().hasPrefix("aether-") && line.contains(":") { return false }
            if line.hasPrefix("Update "), ReleaseFeed.isCommit(String(line.dropFirst(7))) { return false }
            return true
        }
        while kept.first?.isEmpty == true { kept.removeFirst() }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept
    }

    static func render(_ notes: String, ink: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // Blank lines become paragraph spacing rather than whole empty lines.
        for (index, line) in lines(notes).filter({ !$0.isEmpty }).enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            paragraph.lineSpacing = 1.5
            var text = line
            var font = NSFont.systemFont(ofSize: 12)
            var color = ink.withAlphaComponent(0.82)
            if let hashes = line.firstIndex(where: { $0 != "#" }), hashes > line.startIndex, line[hashes] == " " {
                text = String(line[hashes...]).trimmingCharacters(in: .whitespaces)
                font = .systemFont(ofSize: 12.5, weight: .semibold)
                color = ink.withAlphaComponent(0.96)
                paragraph.paragraphSpacingBefore = index > 0 ? 8 : 0
            } else if let marker = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                text = "•\t" + line.dropFirst(marker.count)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
                paragraph.headIndent = 12
            }
            out.append(inline(text, font: font, color: color, paragraph: paragraph))
        }
        return out
    }

    private static func inline(_ text: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }
}

/// A progress ring that spins while waiting, fills as bytes arrive, and draws a checkmark when the update is verified.
final class UpdateRing: NSView {
    enum Mode: Equatable {
        case spinning
        case progress(Double)
        case done
        case failed
    }

    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let check = CAShapeLayer()
    private let alert = CAShapeLayer()
    private(set) var mode: Mode = .spinning
    private var lineWidth: CGFloat { max(2, bounds.width * 0.075) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [track, fill, check, alert] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        check.strokeEnd = 0
        alert.opacity = 0
        apply(.spinning, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? { "Update progress" }
    override func accessibilityValue() -> Any? {
        switch mode {
        case .progress(let fraction): NSNumber(value: Int((fraction * 100).rounded()))
        case .done: NSNumber(value: 100)
        default: nil
        }
    }

    override func layout() {
        super.layout()
        let inset = lineWidth / 2 + 1
        let circle = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ring = CGMutablePath()
        // From twelve o'clock, clockwise.
        ring.addArc(center: center, radius: circle.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, fill, check, alert] {
            shape.frame = bounds
            shape.lineWidth = lineWidth
        }
        track.path = ring
        fill.path = ring
        let side = circle.width
        let tick = CGMutablePath()
        tick.move(to: CGPoint(x: center.x - side * 0.2, y: center.y + side * 0.01))
        tick.addLine(to: CGPoint(x: center.x - side * 0.05, y: center.y - side * 0.15))
        tick.addLine(to: CGPoint(x: center.x + side * 0.22, y: center.y + side * 0.16))
        check.path = tick
        let bang = CGMutablePath()
        bang.move(to: CGPoint(x: center.x, y: center.y + side * 0.2))
        bang.addLine(to: CGPoint(x: center.x, y: center.y - side * 0.04))
        bang.move(to: CGPoint(x: center.x, y: center.y - side * 0.19))
        bang.addLine(to: CGPoint(x: center.x, y: center.y - side * 0.2))
        alert.path = bang
        recolor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    func recolor() {
        let ink = UpdateCard.ink
        let accent = mode == .failed ? NSColor.systemRed : NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = ink.withAlphaComponent(0.14).cgColor
            fill.strokeColor = accent.cgColor
            check.strokeColor = accent.cgColor
            alert.strokeColor = accent.cgColor
        }
    }

    func show(_ stage: UpdateStage) {
        switch stage {
        case .checking, .verifying, .restarting: apply(.spinning, animated: true)
        case .downloading(_, let progress): apply(.progress(progress.fraction), animated: true)
        case .upToDate, .ready, .demoFinished: apply(.done, animated: true)
        case .failed: apply(.failed, animated: true)
        }
    }

    func apply(_ next: Mode, animated: Bool) {
        let previous = mode
        mode = next
        recolor()
        let animate = animated && window != nil
        let reduced = Motion.reduced
        switch next {
        case .spinning:
            set(fill, "strokeEnd", 0.24, animate: animate && previous != .spinning)
            set(check, "strokeEnd", 0, animate: false)
            set(alert, "opacity", 0, animate: animate)
            spin(true, reduced: reduced)
        case .progress(let fraction):
            spin(false, reduced: reduced)
            set(fill, "strokeEnd", CGFloat(max(0.015, fraction)), animate: animate && !reduced, duration: 0.45)
            set(check, "strokeEnd", 0, animate: false)
            set(alert, "opacity", 0, animate: false)
        case .done:
            spin(false, reduced: reduced)
            set(alert, "opacity", 0, animate: false)
            set(fill, "strokeEnd", 1, animate: animate, duration: reduced ? 0.15 : 0.35)
            // The tick draws itself just after the ring closes, so verifying reads as one gesture.
            set(check, "strokeEnd", 1, animate: animate && previous != .done, duration: reduced ? 0.15 : 0.32, delay: reduced ? 0 : 0.22)
        case .failed:
            spin(false, reduced: reduced)
            set(fill, "strokeEnd", 1, animate: animate)
            set(check, "strokeEnd", 0, animate: false)
            set(alert, "opacity", 1, animate: animate)
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func set(_ shape: CAShapeLayer, _ key: String, _ value: CGFloat, animate: Bool, duration: TimeInterval = 0.3, delay: TimeInterval = 0) {
        let from = (shape.presentation() ?? shape).value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard animate else {
            shape.removeAnimation(forKey: key)
            return
        }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = Motion.ease()
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        shape.add(animation, forKey: key)
    }

    /// Reduce Motion swaps the spin for a slow breath.
    private func spin(_ on: Bool, reduced: Bool) {
        guard on else {
            fill.removeAnimation(forKey: "spin")
            return
        }
        guard fill.animation(forKey: "spin") == nil else { return }
        if reduced {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.35
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            fill.add(breathe, forKey: "spin")
            return
        }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * CGFloat.pi
        turn.duration = 0.95
        turn.repeatCount = .infinity
        fill.add(turn, forKey: "spin")
    }
}

/// The update card: Liquid Glass that slides in under the tab strip at the top-right of the window.
/// The view spans the canvas so it can follow resizes, but only the card takes clicks.
final class UpdateCard: NSView {
    var onInstall: (() -> Void)?
    var onLater: (() -> Void)?
    var onRetry: (() -> Void)?

    let ring = UpdateRing(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    private let glass = NSGlassEffectView()
    private let card = NSView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let notesButton = NSButton()
    private let notesScroll = NSScrollView()
    private let notesText = NSTextView()
    private let secondary = NSButton()
    private let primary = NSButton()
    private(set) var stage: UpdateStage?
    private var notesOpen = false
    private var revealed = false
    private var leaving = false
    private var settleToken = 0
    private var settlePending = false
    private var hovering = false

    private static let margin: CGFloat = 14
    private static let width: CGFloat = 348
    private static let pad: CGFloat = 14

    /// White on dark glass, near-black on light glass, following the text tone setting.
    @MainActor static var ink: NSColor {
        AppModel.shared.settings.text.effective == .light ? .white : NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1)
    }

    static func name(of offer: ReleaseFeed.Offer) -> String {
        let local = BuildStamp.current.version
        if !offer.version.isEmpty, offer.version != local { return "Aether \(offer.version)" }
        return "Aether build \(String(offer.commit.prefix(7)))"
    }

    /// "Version 2.1.0 · Build 4f9c2e1 · Oct 29, 2026"
    static func byline(of offer: ReleaseFeed.Offer) -> String {
        var parts: [String] = []
        if !offer.version.isEmpty { parts.append("Version \(offer.version)") }
        parts.append("Build \(String(offer.commit.prefix(7)))")
        if let published = offer.published {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setAccessibilityRole(.staticText)
        subtitle.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        subtitle.maximumNumberOfLines = 3
        subtitle.lineBreakMode = .byWordWrapping
        configure(notesButton, action: #selector(notesPressed))
        notesButton.bezelStyle = .inline
        notesButton.isBordered = false
        configure(secondary, action: #selector(secondaryPressed))
        configure(primary, action: #selector(primaryPressed))
        primary.tintProminence = .primary
        notesText.isEditable = false
        notesText.isSelectable = true
        notesText.drawsBackground = false
        notesText.textContainerInset = NSSize(width: 0, height: 4)
        notesText.textContainer?.lineFragmentPadding = 0
        notesText.isVerticallyResizable = true
        notesText.autoresizingMask = [.width]
        notesText.setAccessibilityLabel("Release notes")
        notesScroll.documentView = notesText
        notesScroll.drawsBackground = false
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true
        notesScroll.scrollerStyle = .overlay
        notesScroll.isHidden = true
        for view in [ring, title, subtitle, notesScroll, notesButton, secondary, primary] as [NSView] {
            card.addSubview(view)
        }
        card.wantsLayer = true
        glass.style = .regular
        glass.cornerRadius = 18
        glass.contentView = card
        glass.wantsLayer = true
        glass.setAccessibilityElement(true)
        glass.setAccessibilityRole(.group)
        glass.setAccessibilityLabel("Aether update")
        addSubview(glass)
        glass.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, action: Selector) {
        button.bezelStyle = .glass
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        // Clicking the card must not pull focus out of the terminal.
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
    }

    // MARK: Stages

    func show(_ next: UpdateStage) {
        let changedKind = stage?.kind != next.kind
        let changedOffer = stage?.offer?.commit != next.offer?.commit
        stage = next
        if leaving {
            // Called back mid-exit: come in again rather than stay faded out.
            leaving = false
            revealed = false
            glass.layer?.removeAnimation(forKey: "vapor")
            glass.layer?.filters = nil
        }
        // Only a new stage restarts the clock. Restyles and progress ticks must not keep a card up forever.
        if changedKind {
            settleToken += 1
            settlePending = false
        }
        if changedKind, revealed {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.reduced ? 0.15 : 0.22
            fade.timingFunction = Motion.ease()
            card.layer?.add(fade, forKey: "stage")
        }
        if changedOffer { notesOpen = false }
        let ink = Self.ink
        // A light wash behind the words, so a busy prompt underneath doesn't read through the glass.
        glass.tintColor = AppModel.shared.settings.text.effective == .light
            ? NSColor(white: 0, alpha: 0.3) : NSColor(white: 1, alpha: 0.35)
        title.textColor = ink.withAlphaComponent(0.96)
        subtitle.textColor = ink.withAlphaComponent(0.62)
        notesButton.contentTintColor = NSColor.controlAccentColor
        ring.show(next)

        var titleText = ""
        var subtitleText = ""
        var secondaryTitle: String?
        var primaryTitle: String?
        var notes = ""
        switch next {
        case .checking:
            titleText = "Checking for updates…"
            subtitleText = "Looking for a newer Aether"
        case .upToDate:
            titleText = "Aether is up to date"
            let stamp = BuildStamp.current
            subtitleText = stamp.version.isEmpty ? "Build \(stamp.shortCommit)" : "Version \(stamp.version) · Build \(stamp.shortCommit)"
        case .downloading(let offer, let progress):
            titleText = progress.thenRestart ? "Restarting after download" : "Downloading \(Self.name(of: offer))"
            subtitleText = progress.detail
            secondaryTitle = "Hide"
            notes = offer.notes
        case .verifying(let offer):
            titleText = "Verifying \(Self.name(of: offer))"
            subtitleText = "Checking its checksum and signature"
            notes = offer.notes
        case .ready(let offer):
            titleText = "\(Self.name(of: offer)) is ready"
            subtitleText = Self.byline(of: offer)
            secondaryTitle = "Later"
            primaryTitle = "Restart to Update"
            notes = offer.notes
        case .restarting(let offer):
            titleText = "Restarting…"
            subtitleText = "Installing \(Self.name(of: offer))"
        case .demoFinished:
            titleText = "Demo finished"
            subtitleText = "AETHER_UPDATE_DEMO plays the card only. Nothing was installed."
            secondaryTitle = "Dismiss"
        case .failed(let message):
            titleText = "Update didn't finish"
            subtitleText = message
            secondaryTitle = "Dismiss"
            primaryTitle = "Try Again"
        }
        title.stringValue = titleText
        subtitle.stringValue = subtitleText
        // Glass buttons pick their own grey, which washes out on dark glass; the text tone decides instead.
        secondary.attributedTitle = NSAttributedString(string: secondaryTitle ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.9),
        ])
        secondary.isHidden = secondaryTitle == nil
        primary.title = primaryTitle ?? ""
        primary.isHidden = primaryTitle == nil
        let hasNotes = !ReleaseNotes.lines(notes).isEmpty && next.kind != 5
        notesButton.isHidden = !hasNotes || (secondaryTitle == nil && primaryTitle == nil)
        if !hasNotes { notesOpen = false }
        if hasNotes, changedOffer || changedKind {
            notesText.textStorage?.setAttributedString(ReleaseNotes.render(notes, ink: ink))
            notesText.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        }
        refreshNotesButton()
        glass.setAccessibilityValue(next.summary)
        if changedKind {
            NSAccessibility.post(element: window ?? self, notification: .announcementRequested, userInfo: [
                .announcement: "\(titleText). \(subtitleText)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        positionCard(animated: revealed && changedKind)
        reveal()
        if changedKind, let linger = next.linger { settle(after: linger) }
    }

    /// Picks up a new text tone.
    func restyle() {
        guard let stage, !leaving else { return }
        let ink = Self.ink
        if let offer = stage.offer {
            notesText.textStorage?.setAttributedString(ReleaseNotes.render(offer.notes, ink: ink))
        }
        show(stage)
    }

    /// Leaves on its own after a moment, unless another stage replaces it first.
    /// The pointer resting on the card holds it; it leaves a moment after the pointer does.
    private func settle(after delay: TimeInterval) {
        let token = settleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.settleToken == token else { return }
            if self.hovering {
                self.settlePending = true
            } else {
                self.dismiss()
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if settlePending {
            settlePending = false
            settle(after: 1.2)
        }
    }

    private func refreshNotesButton() {
        notesButton.title = notesOpen ? "Hide Notes" : "Release Notes"
        notesButton.image = NSImage(systemSymbolName: notesOpen ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        notesButton.imagePosition = .imageTrailing
        notesButton.setAccessibilityLabel(notesOpen ? "Hide release notes" : "Show release notes")
        notesScroll.isHidden = !notesOpen
    }

    // MARK: Motion

    /// Slides in from the right edge. Reduce Motion fades it in instead.
    func reveal() {
        guard !revealed else { return }
        revealed = true
        layoutSubtreeIfNeeded()
        positionCard(animated: false)
        let home = glass.frame
        glass.alphaValue = 0
        if !Motion.reduced { glass.frame = home.offsetBy(dx: 36, dy: 0) }
        Motion.group(Motion.reveal) {
            self.glass.animator().alphaValue = 1
            self.glass.animator().frame = home
        }
    }

    /// Dissolves into vapour, in the launcher's language: blur rising, opacity falling,
    /// a slight lift and swell. Reduce Motion gets a plain quick fade.
    func dismiss() {
        guard !leaving, superview != nil else { return }
        leaving = true
        hovering = false
        settlePending = false
        let finish = { [weak self] in
            guard let self, self.leaving else { return }
            self.removeFromSuperview()
        }
        guard !Motion.reduced, let layer = glass.layer else {
            Motion.group(0.15, { self.glass.animator().alphaValue = 0 }, done: finish)
            return
        }
        let duration = Motion.vapor
        // AppKit anchors the layer at its corner, so the swell is built around the centre by hand.
        let size = layer.bounds.size
        var swell = CATransform3DMakeTranslation(size.width / 2, size.height / 2 + 10, 0)
        swell = CATransform3DScale(swell, 1.04, 1.04, 1)
        swell = CATransform3DTranslate(swell, -size.width / 2, -size.height / 2, 0)
        let lift = CABasicAnimation(keyPath: "transform")
        lift.fromValue = CATransform3DIdentity
        lift.toValue = swell
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        var parts: [CAAnimation] = [lift, fade]
        glass.layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "vapor"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            layer.filters = [blur]
            let rise = CABasicAnimation(keyPath: "filters.vapor.inputRadius")
            rise.fromValue = 0
            rise.toValue = 14
            parts.append(rise)
        }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = duration
        group.timingFunction = Motion.ease()
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        layer.add(group, forKey: "vapor")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        positionCard(animated: false)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        positionCard(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !leaving, glass.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    @objc func notesPressed() {
        notesOpen.toggle()
        refreshNotesButton()
        notesText.scroll(.zero)
        positionCard(animated: true)
    }

    @objc private func secondaryPressed() {
        if case .failed = stage {
            dismiss()
        } else if stage == .demoFinished {
            dismiss()
        } else {
            onLater?()
        }
    }

    @objc private func primaryPressed() {
        switch stage {
        case .ready: onInstall?()
        case .failed: onRetry?()
        default: break
        }
    }

    // MARK: Layout

    /// Top-right, just under the tab strip, so it never covers the prompt at the bottom of a pane.
    private var topInset: CGFloat {
        guard let canvas = superview as? DeskCanvas else { return Self.margin }
        return max(Self.margin, bounds.maxY - canvas.contentArea().maxY + 10)
    }

    private func positionCard(animated: Bool) {
        let pad = Self.pad
        let width = min(Self.width, max(220, bounds.width - Self.margin * 2))
        let ringSide: CGFloat = 34
        let column = pad + ringSide + 12
        let textWidth = width - column - pad
        title.frame.size = NSSize(width: textWidth, height: ceil(title.intrinsicContentSize.height))
        subtitle.preferredMaxLayoutWidth = textWidth
        let subtitleHeight = ceil(subtitle.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
        let textHeight = title.frame.height + 2 + subtitleHeight
        let head = max(ringSide, textHeight)

        let notesWidth = width - pad * 2
        var notesHeight: CGFloat = 0
        let hasButtons = !primary.isHidden || !secondary.isHidden || !notesButton.isHidden
        if notesOpen {
            notesText.frame.size.width = notesWidth
            if let container = notesText.textContainer, let manager = notesText.layoutManager {
                container.size = NSSize(width: notesWidth, height: .greatestFiniteMagnitude)
                manager.ensureLayout(for: container)
                // Never taller than the window has room for below the card's other rows.
                let room = bounds.height - topInset - Self.margin - pad * 2 - head - 10 - (hasButtons ? 40 : 0)
                notesHeight = max(40, min(200, room, ceil(manager.usedRect(for: container).height) + 10))
            }
        }
        let buttonHeight: CGFloat = 28
        var height = pad + head + pad
        if notesOpen { height += 10 + notesHeight }
        if hasButtons { height += 12 + buttonHeight }

        let frame = NSRect(
            x: bounds.maxX - width - Self.margin,
            y: bounds.maxY - topInset - height,
            width: width,
            height: height
        )
        let place = {
            var y = height - pad - head
            self.ring.frame = NSRect(x: pad, y: y + head - ringSide, width: ringSide, height: ringSide)
            let textTop = y + head - (head - textHeight) / 2
            self.title.frame.origin = NSPoint(x: column, y: textTop - self.title.frame.height)
            self.subtitle.frame = NSRect(x: column, y: textTop - textHeight, width: textWidth, height: subtitleHeight)
            if self.notesOpen {
                y -= 10 + notesHeight
                self.notesScroll.frame = NSRect(x: pad, y: y, width: notesWidth, height: notesHeight)
                self.notesText.frame.size.height = max(notesHeight, self.notesText.frame.height)
            }
            var right = width - pad
            for button in [self.primary, self.secondary] where !button.isHidden {
                // Measured from the words: the glass bezel's own fitting size cuts "Restart to Update" short.
                let words = button.attributedTitle.size().width
                let buttonWidth = max(ceil(words) + 34, 76)
                right -= buttonWidth
                button.frame = NSRect(x: right, y: pad, width: buttonWidth, height: buttonHeight)
                right -= 8
            }
            self.notesButton.sizeToFit()
            self.notesButton.frame = NSRect(x: pad - 2, y: pad + (buttonHeight - self.notesButton.frame.height) / 2, width: self.notesButton.frame.width, height: self.notesButton.frame.height)
        }
        if animated, revealed {
            Motion.group(Motion.snap) {
                self.glass.animator().frame = frame
                self.card.frame = NSRect(origin: .zero, size: frame.size)
                place()
            }
        } else {
            glass.frame = frame
            card.frame = glass.bounds
            place()
        }
    }
}
