import AppKit
import CoreImage
import PDFKit
import QuartzCore
import SwiftTerm
import WebKit

@MainActor
final class AetherTerminal: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    var onStatus: ((String, String) -> Void)?
    /// Keys typed while the shell is gone. Returning true swallows them.
    var onExitedKey: ((ArraySlice<UInt8>) -> Bool)?
    var remoteSession: String?
    var workingDirectory: () -> String = { System.home() }
    var optionMode: OptionKey = .characters
    var warnMultilinePaste = true
    /// True while SwiftTerm answers the program itself (cursor reports, color queries, mouse and focus reports).
    /// Those replies are not typing, so they never reach broadcast.
    private var replying = false
    private static var optionMonitor: Any?

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        Self.installOptionMonitor()
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
        terminal.registerOscHandler(code: 7501) { [weak self] data in
            let body = String(bytes: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleStatus(body)
                }
            }
        }
    }

    private func handleStatus(_ body: String) {
        if body == "?" || body.hasPrefix("?:") {
            guard remoteSession == nil else { return }
            let reply = "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\"
            deliver(ArraySlice(Array(reply.utf8)))
            return
        }
        var state = ""
        var message = ""
        for part in body.split(separator: ":") {
            let bits = part.split(separator: "=", maxSplits: 1)
            guard bits.count == 2 else { continue }
            if bits[0] == "state" { state = String(bits[1]) }
            if bits[0] == "msg", let data = Data(base64Encoded: String(bits[1])), let text = String(data: data, encoding: .utf8) {
                message = text
            }
        }
        guard !state.isEmpty else { return }
        onStatus?(state, message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        let hasURL = board.canReadObject(forClasses: [NSURL.self])
        let hasText = board.canReadObject(forClasses: [NSString.self])
        let hasImage = board.canReadObject(forClasses: [NSImage.self])
        return (hasURL || hasText || hasImage) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = dropText(from: sender.draggingPasteboard), !text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        insertPasted(text)
        return true
    }

    /// Paths and links come quoted with a trailing space, ready for the next word. Plain text goes in as is.
    private func dropText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { ShellPath.quote($0.path) }.joined(separator: " ") + " "
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { ShellPath.quote($0.isFileURL ? $0.path : $0.absoluteString) }.joined(separator: " ") + " "
        }
        if let image = NSImage(pasteboard: pasteboard), let path = Self.stash(image) {
            return ShellPath.quote(path) + " "
        }
        return pasteboard.string(forType: .string)
    }

    /// Text that arrives all at once, like a drop or Insert Path. A shell in bracketed paste mode
    /// then treats it as one paste instead of running any newline inside it.
    func insertPasted(_ text: String) {
        if terminal.bracketedPasteMode {
            send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }
    }

    /// Drops of pictures are saved to temporary files. Anything older than a day is gone by the next launch.
    static func cleanDropStash() {
        let folder = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("Aether-drop-") && name.hasSuffix(".png") {
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func stash(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aether-drop-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        replying = true
        defer { replying = false }
        super.send(source: source, data: data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if replying {
            deliver(data)
            return
        }
        if let onExitedKey, onExitedKey(data) { return }
        deliver(data)
        onUserInput?(data)
    }

    /// The pane's own way to the shell, local or Cloud, without counting as typing.
    func deliver(_ data: ArraySlice<UInt8>) {
        if let remoteSession {
            SessionHub.shared.input(remoteSession, data: Data(data))
            return
        }
        super.send(source: self, data: data)
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        var rest: [NSEvent] = []
        for event in eventArray {
            if event.type == .keyDown, !hasMarkedText(),
               let bytes = EditingKeys.sequence(keyCode: event.keyCode, flags: event.modifierFlags, optionIsMeta: optionAsMetaKey) {
                send(bytes)
            } else {
                rest.append(event)
            }
        }
        if !rest.isEmpty {
            super.interpretKeyEvents(rest)
        }
    }

    /// SwiftTerm reads `optionAsMetaKey` once per key. For "Left Option is Meta" it is set just before each key
    /// from the device bits, 0x20 for the left Option key.
    private static func installOptionMonitor() {
        guard optionMonitor == nil else { return }
        optionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                guard let terminal = event.window?.firstResponder as? AetherTerminal, terminal.optionMode == .leftMeta else { return }
                let left = event.modifierFlags.rawValue & 0x20 != 0
                terminal.optionAsMetaKey = event.modifierFlags.contains(.option) && left
            }
            return event
        }
    }

    private func pasteAnyway(_ sender: Any) {
        super.paste(sender)
    }

    override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard PasteGuard.shouldWarn(text, bracketed: terminal.bracketedPasteMode, enabled: warnMultilinePaste), let window else {
            super.paste(sender)
            return
        }
        let lines = PasteGuard.lineCount(text)
        let alert = NSAlert()
        alert.messageText = lines == 1 ? "Paste a line that ends in Return?" : "Paste \(lines) lines?"
        let preview = text.trimmingCharacters(in: .newlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(5)
            .map { $0.count > 80 ? String($0.prefix(79)) + "…" : String($0) }
            .joined(separator: "\n")
        alert.informativeText = "The shell runs each line as it arrives.\n\n" + preview + (lines > 5 ? "\n…" : "")
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Paste as One Line")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if alert.suppressionButton?.state == .on {
                AppModel.shared.updateSettings { $0.warnMultilinePaste = false }
            }
            switch response {
            case .alertFirstButtonReturn:
                self.pasteAnyway(sender)
            case .alertSecondButtonReturn:
                self.insertText(PasteGuard.oneLine(text), replacementRange: NSRange(location: 0, length: 0))
            default:
                break
            }
            self.window?.makeFirstResponder(self)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchScreenScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScreenScale()
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if PathOpener.open(link, cwd: workingDirectory()) { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.clickCount == 1,
           !event.modifierFlags.contains(.shift),
           self.selection?.active != true,
           let token = token(at: event),
           PathOpener.open(token, cwd: workingDirectory()) {
            return
        }
        super.mouseUp(with: event)
    }

    private func matchScreenScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
    }

    private func token(at event: NSEvent) -> String? {
        guard let terminal, terminal.cols > 0, terminal.rows > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return nil }
        let cellWidth = max(1, bounds.width / CGFloat(terminal.cols))
        let cellHeight = max(1, bounds.height / CGFloat(terminal.rows))
        let column = min(terminal.cols - 1, max(0, Int(local.x / cellWidth)))
        let row = min(terminal.rows - 1, max(0, Int((bounds.height - local.y) / cellHeight)))
        guard let line = terminal.getLine(row: row) else { return nil }
        let text = line.translateToString(trimRight: true)
        guard !text.isEmpty else { return nil }
        let pattern = #"(?:https?://|mailto:)[^\s<>\"']+|(?:~|\.\.?|[A-Za-z0-9_])[A-Za-z0-9_./~+\-]*[A-Za-z0-9](?::\d+(?::\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var found: String?
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let span = Range(match.range, in: text) else { return }
            let start = text.distance(from: text.startIndex, to: span.lowerBound)
            let end = text.distance(from: text.startIndex, to: span.upperBound)
            if column >= start - 1, column <= end {
                found = String(text[span])
                stop.pointee = true
            }
        }
        return found
    }
}

@MainActor
final class PaneChrome: NSView {
    let paneID: String
    var onSelect: (() -> Void)?
    let header = PaneHeader()
    let terminal: AetherTerminal
    let exitBanner = ExitBanner()
    private let clip = NSView()
    private let stage = StageHost()
    private let outline = PassthroughView()
    private let rest = PassthroughView()
    private var preview: NSView?
    private var appliedFocus: Bool?
    private var appliedRest: FocusRest?
    private var appliedTone: TextTone?
    private var appliedBlur: Double = -1
    private var appliedBroadcast = false
    private static let broadcastColor = NSColor(srgbRed: 0.99, green: 0.66, blue: 0.2, alpha: 0.95)

    init(paneID: String, font: NSFont) {
        self.paneID = paneID
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.cursorStyle = .steadyBar
        options.termName = "xterm-256color"
        options.enableSixelReported = true
        options.kittyImageCacheLimitBytes = 320 * 1024 * 1024
        terminal = AetherTerminal(frame: .zero, font: font, options: options)
        terminal.scrollerStyle = .overlay
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = 20
        stage.wantsLayer = true
        stage.layerUsesCoreImageFilters = true
        rest.wantsLayer = true
        rest.layer?.backgroundColor = NSColor.black.cgColor
        rest.alphaValue = 0
        for view in [clip, stage, terminal, header, exitBanner, rest, outline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        addSubview(clip)
        clip.addSubview(stage)
        stage.addSubview(terminal)
        clip.addSubview(header)
        clip.addSubview(exitBanner)
        clip.addSubview(rest)
        clip.addSubview(outline)
        exitBanner.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let radius = layer?.cornerRadius ?? 16
        clip.frame = bounds
        clip.layer?.cornerRadius = radius
        clip.layer?.masksToBounds = true
        clip.layer?.mask = nil
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 4)
        let headerHeight: CGFloat = 34
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        stage.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        let bannerHeight: CGFloat = exitBanner.isHidden ? 0 : 36
        exitBanner.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 28)
        let insetX: CGFloat = 18
        let insetBottom: CGFloat = 14
        terminal.frame = NSRect(
            x: insetX,
            y: bannerHeight + insetBottom,
            width: max(0, stage.bounds.width - insetX * 2),
            height: max(0, stage.bounds.height - bannerHeight - insetBottom)
        )
        preview?.frame = terminal.frame
        rest.frame = bounds
        outline.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        outline.layer?.cornerRadius = max(0, radius - 0.5)
        if outline.layer?.borderWidth ?? 0 < 1 {
            outline.layer?.borderWidth = 1
            outline.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        }
    }

    func showPreview(kind: String, source: String) -> Bool {
        preview?.removeFromSuperview()
        let view: NSView
        if kind == "pdf" {
            guard let document = PDFDocument(url: URL(fileURLWithPath: source)) else { return false }
            let pdf = PDFView()
            pdf.document = document
            pdf.autoScales = true
            view = pdf
        } else {
            guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else { return false }
            let web = WKWebView()
            web.load(URLRequest(url: url))
            view = web
        }
        preview = view
        view.translatesAutoresizingMaskIntoConstraints = true
        terminal.isHidden = true
        stage.addSubview(view)
        needsLayout = true
        return true
    }

    func setFocused(_ focused: Bool, settings: Settings) {
        let nextBlur = (!focused && settings.focusRest == .blur) ? settings.blurAmount : 0
        let broadcasting = AppModel.shared.isBroadcasting(pane: paneID)
        if appliedFocus == focused, appliedRest == settings.focusRest, appliedTone == settings.text, abs(appliedBlur - nextBlur) < 0.01,
           appliedBroadcast == broadcasting {
            return
        }
        let animate = appliedFocus != nil && appliedBroadcast == broadcasting
        appliedBroadcast = broadcasting
        header.setBroadcasting(broadcasting)
        appliedFocus = focused
        appliedRest = settings.focusRest
        appliedTone = settings.text
        appliedBlur = nextBlur
        let dim: CGFloat = focused || settings.focusRest != .dim ? 0 : (settings.text == .light ? 0.22 : 0.12)
        // Enough smear that glyphs and pictures stop being readable, even toward the low end of the slider.
        let radius = nextBlur > 0.01 ? CGFloat(16 + nextBlur * 26) : 0
        header.setFindVisible(focused)
        applyContentBlur(radius: radius, animated: animate, blurMode: settings.focusRest == .blur)
        if animate {
            animateBorder(focused)
            Motion.fade(rest.layer, to: Float(dim), key: "dim")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if broadcasting {
                outline.layer?.borderWidth = focused ? 2.5 : 2
                outline.layer?.borderColor = Self.broadcastColor.cgColor
            } else {
                outline.layer?.borderWidth = focused ? 1.5 : 0
                outline.layer?.borderColor = NSColor.white.withAlphaComponent(focused ? 0.62 : 0).cgColor
            }
            rest.alphaValue = dim
            CATransaction.commit()
        }
    }

    /// Blurs the terminal's own pixels. The filter stays attached while Blur is the setting,
    /// so focusing a pane only changes the radius and does not blank the window.
    private func applyContentBlur(radius: CGFloat, animated: Bool, blurMode: Bool) {
        guard let layer = stage.layer else { return }
        let name = "aetherBlur"
        if !blurMode {
            if layer.filters != nil || layer.shouldRasterize {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.filters = nil
                layer.shouldRasterize = false
                CATransaction.commit()
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !layer.shouldRasterize {
            layer.rasterizationScale = stage.window?.backingScaleFactor ?? 2
            layer.shouldRasterize = true
        }
        let filters = (layer.filters as? [CIFilter]) ?? []
        let filter: CIFilter
        if let existing = filters.first(where: { $0.name == name }) {
            filter = existing
        } else if let created = CIFilter(name: "CIGaussianBlur") {
            created.name = name
            created.setDefaults()
            created.setValue(radius, forKey: kCIInputRadiusKey)
            layer.filters = [created]
            filter = created
        } else {
            CATransaction.commit()
            return
        }
        CATransaction.commit()
        let current = (filter.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue ?? 0
        if animated, abs(current - Double(radius)) > 0.4 {
            let spring = CASpringAnimation(keyPath: "filters.\(name).inputRadius")
            spring.fromValue = current
            spring.toValue = radius
            spring.mass = 0.6
            spring.stiffness = 280
            spring.damping = 24
            spring.duration = min(max(spring.settlingDuration, 0.22), 0.4)
            spring.timingFunction = Motion.ease()
            layer.add(spring, forKey: "aetherBlurRadius")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        CATransaction.commit()
    }

    private func animateBorder(_ focused: Bool) {
        guard let layer = outline.layer else { return }
        let width: CGFloat = appliedBroadcast ? (focused ? 2.5 : 2) : (focused ? 1.5 : 1)
        // borderColor is a CGColor. Animating the presentation layer's color
        // releases a pointer the window server still owns, which crashes in
        // the next autorelease pool drain.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = appliedBroadcast ? Self.broadcastColor.cgColor : NSColor.white.withAlphaComponent(focused ? 0.55 : 0.2).cgColor
        CATransaction.commit()
        let widthAnim = CABasicAnimation(keyPath: "borderWidth")
        widthAnim.fromValue = layer.presentation()?.borderWidth ?? layer.borderWidth
        widthAnim.toValue = width
        widthAnim.duration = Motion.close
        widthAnim.timingFunction = Motion.ease()
        layer.borderWidth = width
        layer.add(widthAnim, forKey: "borderWidth")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let hit = super.hitTest(point), hit === self || hit.isDescendant(of: self) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        window?.makeFirstResponder(terminal)
    }

    func setBodyShade(_ color: NSColor) {
        stage.layer?.backgroundColor = color.cgColor
    }

    func showExit(code: Int32?) {
        exitBanner.isHidden = false
        exitBanner.setCode(code)
        needsLayout = true
    }

    func showLastRan(_ command: String) {
        exitBanner.isHidden = false
        exitBanner.setLastRan(command)
        needsLayout = true
    }

    func hideExit() {
        exitBanner.isHidden = true
        needsLayout = true
    }
}

@MainActor
final class PaneHeader: NSView {
    var onFocus: (() -> Void)?
    var onGripDrag: ((NSEvent) -> Void)?
    var onWindowDrag: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onFind: (() -> Void)?
    private var activity = ""
    private var activityState = ""
    private var cloudNote = ""
    private var broadcasting = false

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let findButton = NSButton()
    private var tone: TextTone = .light
    private var scrim = NSColor.black.withAlphaComponent(0.55)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = NSColor.white.withAlphaComponent(0.92)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = true
        addSubview(titleField)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close terminal")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.toolTip = "Close terminal"
        addSubview(closeButton)

        findButton.isBordered = false
        findButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
        findButton.imageScaling = .scaleProportionallyDown
        findButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        findButton.target = self
        findButton.action = #selector(findPressed)
        findButton.translatesAutoresizingMaskIntoConstraints = true
        findButton.toolTip = "Find  ⌘F"
        findButton.alphaValue = 0
        addSubview(findButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCaption(_ text: String, tone: TextTone) {
        self.tone = tone
        titleField.stringValue = text
        let color: NSColor = tone == .light ? .white : NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1)
        titleField.textColor = color.withAlphaComponent(0.92)
        closeButton.contentTintColor = color.withAlphaComponent(0.75)
        findButton.contentTintColor = color.withAlphaComponent(0.75)
        needsDisplay = true
    }

    func setFindVisible(_ visible: Bool) {
        findButton.alphaValue = visible ? 1 : 0
    }

    func setCloud(_ note: String) {
        cloudNote = note
        needsDisplay = true
    }

    func setBroadcasting(_ on: Bool) {
        guard broadcasting != on else { return }
        broadcasting = on
        needsDisplay = true
    }

    func setActivity(state: String, message: String) {
        activityState = state
        activity = message
        needsDisplay = true
    }

    func setScrim(_ color: NSColor) {
        scrim = color
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 36, y: 5, width: 24, height: 24)
        findButton.frame = NSRect(x: bounds.width - 62, y: 5, width: 24, height: 24)
        titleField.frame = NSRect(x: 34, y: 7, width: max(0, bounds.width - 108), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor = tone == .light ? .white : .black
        scrim.setFill()
        bounds.fill()
        ink.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 1)).fill()
        let grip = ink.withAlphaComponent(0.55)
        grip.setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let dot = NSRect(x: 16 + CGFloat(column) * 5, y: 11 + CGFloat(row) * 5, width: 2.4, height: 2.4)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
        if activityState == "working" || activityState == "blocked" || activityState == "done" || activityState == "error" {
            let color: NSColor
            switch activityState {
            case "blocked": color = NSColor(srgbRed: 0.96, green: 0.78, blue: 0.45, alpha: 0.95)
            case "error": color = NSColor(srgbRed: 0.95, green: 0.45, blue: 0.42, alpha: 0.95)
            case "done": color = NSColor(srgbRed: 0.55, green: 0.9, blue: 0.7, alpha: 0.95)
            default: color = NSColor.white.withAlphaComponent(0.92)
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 78, y: 14, width: 7, height: 7)).fill()
        }
        var noteRight = bounds.width - 90
        if broadcasting {
            let pill = NSAttributedString(string: "Broadcasting", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            ])
            let size = pill.size()
            let frame = NSRect(x: bounds.width - 92 - size.width - 14, y: 9, width: size.width + 14, height: 16)
            NSColor(srgbRed: 0.99, green: 0.66, blue: 0.2, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            pill.draw(at: NSPoint(x: frame.minX + 7, y: frame.minY + (frame.height - size.height) / 2))
            noteRight = frame.minX - 6
        }
        guard !cloudNote.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        let caption = NSAttributedString(string: cloudNote, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: ink.withAlphaComponent(0.78),
            .paragraphStyle: style,
        ])
        caption.draw(in: NSRect(x: 72, y: 11, width: max(40, noteRight - 72), height: 14))
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        let local = convert(event.locationInWindow, from: nil)
        if local.x < 26 {
            onGripDrag?(event)
            return
        }
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        onWindowDrag?(event)
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: 26, height: bounds.height), cursor: .openHand)
        addCursorRect(NSRect(x: 26, y: 0, width: max(0, bounds.width - 56), height: bounds.height), cursor: .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === findButton, findButton.alphaValue < 0.2 { return self }
        return hit
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func findPressed() {
        onFind?()
    }
}

@MainActor
final class ExitBanner: NSView {
    var onRestart: (() -> Void)?
    var onClose: (() -> Void)?
    var onRunAgain: ((String) -> Void)?
    private(set) var lastRan: String?
    private let label = NSTextField(labelWithString: "Shell exited")
    private let button = NSButton()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        for (control, action) in [(button, #selector(primary)), (closeButton, #selector(secondary))] {
            control.isBordered = false
            control.contentTintColor = .white
            control.font = .systemFont(ofSize: 12, weight: .semibold)
            control.target = self
            control.action = action
            control.translatesAutoresizingMaskIntoConstraints = true
            addSubview(control)
        }
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCode(_ code: Int32?) {
        lastRan = nil
        let failed: Bool
        switch code {
        case 0?:
            label.stringValue = "Shell exited"
            failed = false
        case let code?:
            label.stringValue = "Exited with code \(code)"
            failed = true
        case nil:
            label.stringValue = "Process stopped"
            failed = true
        }
        let tint = failed ? NSColor(srgbRed: 0.62, green: 0.12, blue: 0.12, alpha: 0.7) : NSColor.black.withAlphaComponent(0.45)
        layer?.backgroundColor = tint.cgColor
        button.title = "Restart ↩"
        closeButton.title = "Close ⎋"
        needsLayout = true
    }

    func setLastRan(_ command: String) {
        lastRan = command
        label.stringValue = "Last ran `\(command)`"
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        button.title = "Run Again"
        closeButton.title = "Dismiss"
        needsLayout = true
    }

    override func layout() {
        let closeWidth = max(64, closeButton.intrinsicContentSize.width + 12)
        let buttonWidth = max(74, button.intrinsicContentSize.width + 12)
        closeButton.frame = NSRect(x: bounds.width - closeWidth - 6, y: 2, width: closeWidth, height: 24)
        button.frame = NSRect(x: closeButton.frame.minX - buttonWidth, y: 2, width: buttonWidth, height: 24)
        label.frame = NSRect(x: 10, y: 4, width: max(0, button.frame.minX - 16), height: 20)
    }

    @objc private func primary() {
        if let lastRan {
            onRunAgain?(lastRan)
        } else {
            onRestart?()
        }
    }

    @objc private func secondary() {
        onClose?()
    }
}

/// Hosts the terminal. Rasterized blur would otherwise refuse the click and
/// leave focus on the pane that was active before.
final class StageHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() where !subview.isHidden && subview.alphaValue > 0.01 {
            if let hit = subview.hitTest(local) { return hit }
            let inside = subview.convert(local, from: self)
            if subview.bounds.contains(inside) { return subview }
        }
        return self
    }
}

final class PassthroughView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class DividerGrip: NSView {
    var axis: Axis = .row
    var splitID: String = ""
    var span: CGFloat = 1
    var onDrag: ((NSEvent, DividerGrip) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDrag?(event, self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .row ? .resizeLeftRight : .resizeUpDown)
    }
}

@MainActor
final class DropHighlight: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class PaneController {
    let id: String
    let chrome: PaneChrome
    private(set) var command: String?
    var cwd: String
    var title: String
    private var didShutdown = false
    /// The shell is gone and the exit banner is up.
    private(set) var exited = false
    private(set) var lastExitCode: Int32?
    /// Set once the shell reports its directory with OSC 7. Polling then leaves the directory alone.
    private(set) var reportsDirectory = false

    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectory: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onRestart: (() -> Void)?
    var onClose: (() -> Void)?
    var onGripDrag: ((NSEvent) -> Void)?
    var onWindowDrag: ((NSEvent) -> Void)?

    init(id: String, cwd: String, command: String?, settings: Settings) {
        self.id = id
        self.cwd = cwd
        self.command = command
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        title = command?.split(separator: " ").first.map(String.init) ?? folder
        chrome = PaneChrome(paneID: id, font: PaneController.font(size: settings.fontSize))
        apply(settings)
        chrome.header.setCaption(caption, tone: settings.text)
        chrome.terminal.processDelegate = DelegateBridge.shared
        DelegateBridge.shared.register(self)
        wireChrome()
    }

    var caption: String {
        let path = System.displayPath(cwd)
        if title.isEmpty { return path }
        return "\(title)   \(path)"
    }

    var holdsPreview = false

    func launch() {
        if holdsPreview { return }
        exited = false
        if !AppModel.shared.settings.sessionHost.isEmpty, !AppModel.shared.settings.sessionToken.isEmpty {
            launchRemote()
            return
        }
        launchLocal()
    }

    private func launchRemote(attempt: Int = 0) {
        chrome.header.setCloud("Connecting")
        let cols = max(chrome.terminal.terminal.cols, 80)
        let rows = max(chrome.terminal.terminal.rows, 24)
        Task { @MainActor in
            do {
                let id = try await SessionHub.shared.create(cwd: "", cols: cols, rows: rows, command: command)
                chrome.terminal.remoteSession = id
                chrome.header.setCloud(SessionHub.shared.link.title == "Connected" ? "Cloud" : SessionHub.shared.link.title)
                SessionHub.shared.onResync(id) { [weak self] in
                    self?.chrome.terminal.terminal.resetToInitialState()
                }
                SessionHub.shared.onOutput(id) { [weak self] data in
                    self?.chrome.terminal.terminal.feed(byteArray: [UInt8](data))
                }
                SessionHub.shared.onStatus(id) { [weak self] state, message in
                    self?.chrome.header.setActivity(state: state, message: message)
                    if state == "done", message == "exited" {
                        self?.noteExit(0)
                    }
                }
                chrome.hideExit()
            } catch {
                guard !self.didShutdown, attempt < 2 else {
                    let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.chrome.header.setCloud(text)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
                guard !self.didShutdown else { return }
                self.launchRemote(attempt: attempt + 1)
            }
        }
    }

    func screenText() -> String {
        let term: Terminal = chrome.terminal.terminal
        let end = Position(col: max(term.cols - 1, 0), row: max(term.rows - 1, 0))
        return term.getText(start: Position(col: 0, row: 0), end: end)
    }

    func endRemoteSession() {
        if let id = chrome.terminal.remoteSession {
            SessionHub.shared.close(id)
            chrome.terminal.remoteSession = nil
        }
    }

    /// Clears the screen and the scrollback and keeps the line the cursor is on, as ⌘K does in Terminal.app.
    /// A shell sitting at its prompt also gets ⌃L, so it redraws the whole prompt with whatever was typed.
    func clearBuffer() {
        let view = chrome.terminal
        guard let term = view.terminal else { return }
        if term.isCurrentBufferAlternate {
            term.clearScrollback()
            return
        }
        let cursor = term.getCursorLocation()
        var sequence = ""
        if cursor.y > 0 { sequence += "\u{1b}[\(cursor.y)S" }
        sequence += "\u{1b}[1;\(cursor.x + 1)H"
        view.feed(text: sequence)
        term.clearScrollback()
        if view.remoteSession == nil, !exited, view.process.running, runningCommand() == nil {
            view.deliver([0x0c][...])
        }
    }

    /// What is running in the foreground, or nil for a shell waiting at its prompt.
    /// Cloud panes report nil, since their processes live on the server.
    func runningCommand() -> (name: String, line: String)? {
        let view = chrome.terminal
        guard view.remoteSession == nil, !exited, let process = view.process, process.running, process.shellPid > 0 else { return nil }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let name = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
            let line = trimmed.count > 40 ? String(trimmed.prefix(39)) + "…" : trimmed
            return (URL(fileURLWithPath: name).lastPathComponent, line)
        }
        guard process.childfd >= 0 else { return nil }
        let foreground = tcgetpgrp(process.childfd)
        guard foreground > 0, foreground != process.shellPid else { return nil }
        let name = System.processName(pid: foreground) ?? "A command"
        return (name, System.commandLine(pid: foreground) ?? name)
    }

    /// A restored pane that last ran a command starts as a plain shell and offers to run it again.
    func offerRerun(_ command: String) {
        chrome.showLastRan(command)
    }

    private func runAgain(_ command: String) {
        chrome.hideExit()
        windowFocus()
        chrome.terminal.send(txt: command + "\r")
    }

    nonisolated static func closesOnExit(code: Int32?, command: String?, settings: Settings) -> Bool {
        let plain = command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return settings.shellExit == .close && code == 0 && plain
    }

    private func launchLocal() {
        let shell = System.userShell()
        let directory = FileManager.default.fileExists(atPath: cwd) ? cwd : System.home()
        cwd = directory
        if chrome.terminal.process.running {
            chrome.terminal.terminate()
        }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environment = PaneController.shellEnvironment(pane: id)
        if trimmed.isEmpty {
            chrome.terminal.startProcess(executable: shell, args: ["-l"], environment: environment, currentDirectory: directory)
        } else {
            chrome.terminal.startProcess(executable: shell, args: ["-lc", trimmed], environment: environment, currentDirectory: directory)
        }
        chrome.header.setCloud("")
        exited = false
        reportsDirectory = false
        if chrome.exitBanner.lastRan == nil {
            chrome.hideExit()
        }
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        DelegateBridge.shared.unregister(id)
        if chrome.terminal.process.running {
            chrome.terminal.terminate()
        }
    }

    func apply(_ settings: Settings) {
        let foreground: NSColor = settings.text == .light
            ? NSColor(srgbRed: 0.95, green: 0.97, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1)
        let veil: NSColor = settings.text == .light ? .black : .white
        chrome.terminal.font = PaneController.font(size: settings.fontSize)
        chrome.terminal.nativeForegroundColor = foreground
        chrome.terminal.caretColor = foreground
        chrome.terminal.nativeBackgroundColor = .clear
        chrome.setBodyShade(veil.withAlphaComponent(settings.shade))
        chrome.terminal.selectedTextBackgroundColor = foreground.withAlphaComponent(0.22)
        chrome.terminal.appearance = NSAppearance(named: settings.text == .light ? .darkAqua : .aqua)
        chrome.terminal.optionMode = settings.optionKey
        chrome.terminal.optionAsMetaKey = settings.optionKey == .meta
        chrome.terminal.warnMultilinePaste = settings.warnMultilinePaste
        chrome.terminal.workingDirectory = { [weak self] in self?.cwd ?? System.home() }
        chrome.terminal.onStatus = { [weak self] state, message in
            self?.chrome.header.setActivity(state: state, message: message)
        }
        chrome.header.setScrim(veil.withAlphaComponent(max(settings.shade, 0.55)))
        chrome.header.setCaption(caption, tone: settings.text)
        chrome.layer?.cornerRadius = settings.cornerRadius
    }

    func applyShade(_ shade: Double, settings: Settings) {
        let veil: NSColor = settings.text == .light ? .black : .white
        chrome.terminal.nativeBackgroundColor = .clear
        chrome.setBodyShade(veil.withAlphaComponent(shade))
        chrome.header.setScrim(veil.withAlphaComponent(max(shade, 0.55)))
    }

    func noteTitle(_ title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        self.title = cleaned
        onTitle?(cleaned)
    }

    func noteDirectory(_ directory: String) {
        guard !System.sameDirectory(directory, cwd) else { return }
        cwd = directory
        onDirectory?(directory)
    }

    func noteReportedDirectory(_ directory: String) {
        reportsDirectory = true
        noteDirectory(directory)
    }

    func noteExit(_ code: Int32?) {
        exited = true
        lastExitCode = code
        if !Self.closesOnExit(code: code, command: command, settings: AppModel.shared.settings) {
            chrome.showExit(code: code)
        }
        onExit?(code)
    }

    func refreshCaption(tone: TextTone) {
        chrome.header.setCaption(caption, tone: tone)
    }

    private func wireChrome() {
        chrome.terminal.onUserInput = { [weak self] data in
            guard let self else { return }
            if self.chrome.exitBanner.lastRan != nil, data.contains(13) {
                self.chrome.hideExit()
            }
            self.onUserInput?(data)
        }
        chrome.terminal.onExitedKey = { [weak self] data in
            guard let self, self.exited else { return false }
            switch Array(data) {
            case [13], Array("\u{1b}[13u".utf8):
                self.onRestart?()
            case [0x1b], Array("\u{1b}[27u".utf8):
                self.onClose?()
            default:
                break
            }
            return true
        }
        chrome.terminal.onFocus = { [weak self] in
            self?.onFocus?()
        }
        chrome.header.onFocus = { [weak self] in
            self?.onFocus?()
        }
        chrome.header.onGripDrag = { [weak self] event in
            self?.onGripDrag?(event)
        }
        chrome.header.onWindowDrag = { [weak self] event in
            self?.onWindowDrag?(event)
        }
        chrome.header.onClose = { [weak self] in
            self?.onClose?()
        }
        chrome.header.onFind = { [weak self] in
            self?.showFind()
        }
        chrome.exitBanner.onRestart = { [weak self] in
            self?.onRestart?()
        }
        chrome.exitBanner.onClose = { [weak self] in
            guard let self else { return }
            if self.chrome.exitBanner.lastRan != nil {
                self.chrome.hideExit()
            } else {
                self.onClose?()
            }
        }
        chrome.exitBanner.onRunAgain = { [weak self] command in
            self?.runAgain(command)
        }
    }

    private func showFind() {
        onFocus?()
        windowFocus()
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: chrome.terminal, from: item)
    }

    private func windowFocus() {
        chrome.window?.makeKeyAndOrderFront(nil)
        chrome.window?.makeFirstResponder(chrome.terminal)
    }

    /// Variables a parent terminal or an earlier Aether left behind. They describe some other session.
    static let inheritedNoise: Set<String> = [
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "ITERM_SESSION_ID", "ITERM_PROFILE", "LC_TERMINAL", "LC_TERMINAL_VERSION",
        "KITTY_WINDOW_ID", "KITTY_PID", "WEZTERM_PANE", "WEZTERM_EXECUTABLE", "VTE_VERSION", "WT_SESSION",
        "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "GHOSTTY_SHELL_FEATURES",
        "SHLVL", "PWD", "OLDPWD", "_", "LINES", "COLUMNS", "INSIDE_EMACS", "TMUX", "TMUX_PANE", "STY",
        "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS",
    ]

    static func shellEnvironment(pane: String) -> [String] {
        let current = ProcessInfo.processInfo.environment
        var env: [String] = []
        for (key, value) in current.sorted(by: { $0.key < $1.key }) {
            if inheritedNoise.contains(key) || key.hasPrefix("AETHER_") { continue }
            env.append("\(key)=\(value)")
        }
        env.append("TERM=xterm-256color")
        env.append("COLORTERM=truecolor")
        if current["SHELL"] == nil {
            env.append("SHELL=\(System.userShell())")
        }
        if current["TMPDIR"] == nil {
            env.append("TMPDIR=\(NSTemporaryDirectory())")
        }
        if current["HOME"] == nil {
            env.append("HOME=\(System.home())")
        }
        if current["LANG"] == nil, current["LC_ALL"] == nil, current["LC_CTYPE"] == nil {
            env.append("LANG=en_US.UTF-8")
        }
        env.append("TERM_PROGRAM=Aether")
        env.append("AETHER_PANE=\(pane)")
        env.append("AETHER_CONTROL=127.0.0.1:\(AgentDesk.port)")
        env.append("AETHER_AGENT_PLIST=\(System.supportDirectory().appendingPathComponent("agent.plist").path)")
        return env
    }

    static func font(size: Double) -> NSFont {
        let point = CGFloat(size)
        for name in ["SFMono-Regular", "SF Mono", "Menlo"] {
            if let font = NSFont(name: name, size: point) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: point, weight: .regular)
    }
}

/// SwiftTerm delivers process events from a background queue. This bridge hops to the main actor
/// and looks the pane up, so the terminal never retains its controller.
@MainActor
final class DelegateBridge: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = DelegateBridge()
    private var panes: [String: PaneController] = [:]

    func register(_ pane: PaneController) {
        panes[pane.id] = pane
    }

    func unregister(_ id: String) {
        panes[id] = nil
    }

    private func pane(for terminal: AetherTerminal) -> PaneController? {
        panes.values.first { $0.chrome.terminal === terminal }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let terminal = source as? AetherTerminal, let id = terminal.remoteSession else { return }
                SessionHub.shared.resize(id, cols: newCols, rows: newRows)
            }
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let terminal = source as? AetherTerminal else { return }
                DelegateBridge.shared.pane(for: terminal)?.noteTitle(title)
            }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory = System.normalizeDirectory(directory) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let terminal = source as? AetherTerminal else { return }
                DelegateBridge.shared.pane(for: terminal)?.noteReportedDirectory(directory)
            }
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let terminal = source as? AetherTerminal else { return }
                DelegateBridge.shared.pane(for: terminal)?.noteExit(exitCode)
            }
        }
    }
}
