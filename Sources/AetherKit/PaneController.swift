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
    var onShellEvent: ((ShellEvent) -> Void)?
    /// The prompt row the last ⌘↑ or ⌘↓ went to, and where that left the view.
    var lastPromptJump: (row: Int, top: Int)?
    /// Keys typed while the shell is gone. Returning true swallows them.
    var onExitedKey: ((ArraySlice<UInt8>) -> Bool)?
    var remoteSession: String?
    var workingDirectory: () -> String = { System.home() }
    var optionMode: OptionKey = .characters
    var warnMultilinePaste = true
    var copyOnSelect = false
    var onBell: (() -> Void)?
    /// Keyboard copy mode while it is on, and the header pill's text for it. See CopyMode.swift.
    var copyMode: CopyMode?
    var onCopyMode: ((String?) -> Void)?
    /// File paths under the pointer and Quick Look. See Paths.swift.
    var pathPeek = PathPeek()
    /// Set when the selection changes, so a click that leaves an old selection alone does not copy it over the clipboard again.
    private var selectionMoved = false
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
        terminal.registerOscHandler(code: 7502) { [weak self] data in
            guard let event = ShellEvent.parse(String(decoding: data, as: UTF8.self)) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onShellEvent?(event)
                }
            }
        }
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        installPathLinks()
    }

    /// Core Image blur on the stage caches a bitmap of this view. Dirtying
    /// the terminal does not dirty that cache, so `arp -a` / `ping` sat
    /// invisible until the pane next laid out (usually when the command ended).
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        var ancestor: NSView? = superview
        while let view = ancestor {
            if view.layerUsesCoreImageFilters || view.layer?.shouldRasterize == true {
                view.needsDisplay = true
                view.layer?.setNeedsDisplay()
            }
            ancestor = view.superview
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, let action = promptAction(for: event),
           performPromptAction(action) {
            return true
        }
        return super.performKeyEquivalent(with: event)
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

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        placeCopyBlock()
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        var rest: [NSEvent] = []
        for event in eventArray {
            if event.type == .keyDown, !hasMarkedText(),
               let bytes = EditingKeys.sequence(keyCode: event.keyCode, flags: event.modifierFlags, optionIsMeta: optionAsMetaKey, alternateScreen: terminal.isCurrentBufferAlternate) {
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
    /// Copy mode and Quick Look take their keys here first, since SwiftTerm's keyDown clears the selection.
    private static func installOptionMonitor() {
        guard optionMonitor == nil else { return }
        optionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let terminal = event.window?.firstResponder as? AetherTerminal else { return false }
                if terminal.copyMode != nil, !event.modifierFlags.contains(.command) {
                    terminal.handleCopyKey(event)
                    return true
                }
                if terminal.quickLookKey(event) { return true }
                if terminal.optionMode == .leftMeta {
                    let left = event.modifierFlags.rawValue & 0x20 != 0
                    terminal.optionAsMetaKey = event.modifierFlags.contains(.option) && left
                }
                return false
            }
            return taken ? nil : event
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncRemoteSize()
        refreshCopyMode()
    }

    /// SwiftTerm only reports size changes while a local process runs, so Cloud panes tell the server here.
    func syncRemoteSize() {
        guard let remoteSession, let terminal else { return }
        SessionHub.shared.resize(remoteSession, cols: terminal.cols, rows: terminal.rows)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        selectionMoved = false
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchScreenScale()
        syncRenderer()
    }

    /// Draw with SwiftTerm's Metal renderer instead of CoreGraphics.
    var gpuRendering = false {
        didSet { syncRenderer() }
    }
    /// Set once Metal fails, so every pane does not retry a device or shader that will not work.
    private static var metalFailed = false

    /// SwiftTerm wants a window before it builds the Metal view, so this runs again when the pane lands in one.
    private func syncRenderer() {
        let wanted = gpuRendering && !Self.metalFailed
        guard window != nil, wanted != isUsingMetalRenderer else { return }
        do {
            try setUseMetal(wanted)
            // The layer still holds the last CoreGraphics frame, and Metal draws over it on a clear
            // background, so old text ghosted under new text. draw(_:) is a no-op under Metal, so this clears it.
            if wanted { needsDisplay = true }
        } catch {
            Self.metalFailed = true
            NSLog("Aether: GPU rendering unavailable, drawing with CoreGraphics: \(error)")
            try? setUseMetal(false)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScreenScale()
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if PathOpener.open(link, cwd: workingDirectory()) { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// ⌘-click on a path or link goes through SwiftTerm to `requestOpenLink`. See `installPathLinks`.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { selectionMoved = false }
        guard copyOnSelect, selectionMoved, selection?.active == true, let text = getSelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        selectionMoved = true
    }

    override func bell(source: Terminal) {
        onBell?()
    }

    private func matchScreenScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
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
    private var appliedGlass: GlassStyle?
    private var appliedTone: TextTone?
    private var appliedBlur: Double = -1
    private var appliedBroadcast = false
    private var appliedBoost = false
    private let bell = PassthroughView()
    private let bellLayer = CALayer()
    private static let broadcastColor = NSColor(srgbRed: 0.99, green: 0.66, blue: 0.2, alpha: 0.95)

    var isFocused: Bool { appliedFocus == true }

    init(paneID: String, font: NSFont, cursor: CursorStyle = .steadyBar, scrollback: Int = 10_000) {
        self.paneID = paneID
        var options = TerminalOptions.default
        options.scrollback = scrollback
        options.cursorStyle = cursor
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
        stage.layerContentsRedrawPolicy = .onSetNeedsDisplay
        rest.wantsLayer = true
        rest.layer?.backgroundColor = NSColor.black.cgColor
        rest.alphaValue = 0
        for view in [clip, stage, terminal, header, exitBanner, rest, outline, bell] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        addSubview(clip)
        clip.addSubview(stage)
        stage.addSubview(terminal)
        clip.addSubview(header)
        clip.addSubview(exitBanner)
        clip.addSubview(rest)
        clip.addSubview(outline)
        clip.addSubview(bell)
        bellLayer.opacity = 0
        bell.layer?.addSublayer(bellLayer)
        exitBanner.isHidden = true
        header.paneID = paneID
        terminal.onCopyMode = { [weak header] in header?.setCopyMode($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    /// "Terminal: zsh, ~/proj, focused"
    override func accessibilityLabel() -> String? {
        var parts = [header.titleText, header.pathText].filter { !$0.isEmpty }
        if appliedFocus == true { parts.append("focused") }
        return parts.isEmpty ? "Terminal" : "Terminal: " + parts.joined(separator: ", ")
    }

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
        let headerHeight: CGFloat = 26
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        stage.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        let bannerHeight: CGFloat = exitBanner.isHidden ? 0 : 36
        exitBanner.frame = NSRect(x: 6, y: 6, width: max(0, bounds.width - 12), height: 28)
        let insetX: CGFloat = 8
        let insetBottom: CGFloat = 6
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
            outline.layer?.borderColor = borderInk.withAlphaComponent(0.2).cgColor
        }
        bell.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bellLayer.frame = bell.bounds
        bellLayer.cornerRadius = radius
        CATransaction.commit()
    }

    /// White over dark glass, black over light glass.
    private var borderInk: NSColor {
        (appliedTone ?? .light) == .dark ? .black : .white
    }

    /// The outline on the focused pane. Increase Contrast makes it thicker and nearly opaque.
    private func focusBorder(_ focused: Bool) -> (width: CGFloat, color: NSColor) {
        if appliedBoost {
            return (focused ? 2 : 1, borderInk.withAlphaComponent(focused ? 0.9 : 0.4))
        }
        return (focused ? 1.5 : 1, borderInk.withAlphaComponent(focused ? 0.55 : 0.2))
    }

    /// The pane flashes for a bell. With Reduce Motion the edge lights up for a moment instead.
    func flashBell(tone: TextTone, reduceMotion: Bool) {
        let ink: NSColor = tone == .dark ? .black : .white
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bellLayer.removeAllAnimations()
        if reduceMotion {
            bellLayer.backgroundColor = nil
            bellLayer.borderWidth = 2
            bellLayer.borderColor = ink.withAlphaComponent(0.75).cgColor
            bellLayer.opacity = 1
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.bellLayer.opacity = 0
                CATransaction.commit()
            }
            return
        }
        bellLayer.borderWidth = 0
        bellLayer.backgroundColor = ink.withAlphaComponent(tone == .dark ? 0.1 : 0.14).cgColor
        bellLayer.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bellLayer.add(fade, forKey: "bell")
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
        let blurMode = GlassFocus.blursUnfocusedPane(glass: settings.glass, rest: settings.focusRest)
        let radius = GlassFocus.paneBlurRadius(focused: focused, glass: settings.glass, rest: settings.focusRest, amount: settings.blurAmount)
        let broadcasting = AppModel.shared.isBroadcasting(pane: paneID)
        let boost = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if appliedFocus == focused, appliedRest == settings.focusRest, appliedGlass == settings.glass, appliedTone == settings.text.effective,
           abs(appliedBlur - Double(radius)) < 0.4, appliedBroadcast == broadcasting, appliedBoost == boost {
            return
        }
        let animate = appliedFocus != nil && appliedBroadcast == broadcasting
        appliedBroadcast = broadcasting
        appliedBoost = boost
        header.setBroadcasting(broadcasting)
        appliedFocus = focused
        appliedRest = settings.focusRest
        appliedGlass = settings.glass
        appliedTone = settings.text.effective
        appliedBlur = Double(radius)
        let dim: CGFloat = focused || settings.focusRest != .dim ? 0 : (settings.text.effective == .light ? 0.22 : 0.12)
        header.setFindVisible(focused)
        applyContentBlur(radius: radius, animated: animate, blurMode: blurMode)
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
                let border = focusBorder(focused)
                outline.layer?.borderWidth = focused ? border.width : 0
                outline.layer?.borderColor = border.color.cgColor
            }
            rest.alphaValue = dim
            CATransaction.commit()
        }
    }

    /// Redraws the outline after an accessibility display option changed.
    func refreshFocusStyle(settings: Settings) {
        guard let focused = appliedFocus else { return }
        setFocused(focused, settings: settings)
    }

    /// Blurs the terminal's own pixels. The filter stays attached while Blur is the setting,
    /// so focusing a pane only changes the radius and does not blank the window.
    private func applyContentBlur(radius: CGFloat, animated: Bool, blurMode: Bool) {
        guard let layer = stage.layer else { return }
        let name = "aetherBlur"
        if !blurMode {
            animateBlurRadius(on: layer, name: name, to: 0, animated: animated)
            if !animated || Motion.reduced {
                removeContentBlur(from: layer)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + GlassFocus.blurDuration) { [weak self] in
                    guard let self, self.appliedBlur < 0.4 else { return }
                    self.removeContentBlur(from: layer)
                }
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.layerUsesCoreImageFilters = true
        // Rasterize only while the pane is actually blurred. A radius of 0
        // still attached a filter and froze live output on the focused pane.
        if radius > 0.4 {
            if !layer.shouldRasterize {
                layer.rasterizationScale = stage.window?.backingScaleFactor ?? 2
                layer.shouldRasterize = true
            }
        } else {
            layer.shouldRasterize = false
        }
        let filters = (layer.filters as? [CIFilter]) ?? []
        let filter: CIFilter
        if let existing = filters.first(where: { $0.name == name }) {
            filter = existing
        } else if let created = CIFilter(name: "CIGaussianBlur") {
            created.name = name
            created.setDefaults()
            created.setValue(0, forKey: kCIInputRadiusKey)
            layer.filters = [created]
            filter = created
        } else {
            CATransaction.commit()
            return
        }
        CATransaction.commit()
        animateBlurRadius(on: layer, name: name, to: radius, animated: animated)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        CATransaction.commit()
    }

    private func animateBlurRadius(on layer: CALayer, name: String, to radius: CGFloat, animated: Bool) {
        let filters = (layer.filters as? [CIFilter]) ?? []
        guard let filter = filters.first(where: { $0.name == name }) else { return }
        let current = (filter.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue
            ?? (layer.presentation()?.value(forKeyPath: "filters.\(name).inputRadius") as? NSNumber)?.doubleValue
            ?? 0
        layer.removeAnimation(forKey: "aetherBlurRadius")
        if animated, !Motion.reduced, abs(current - Double(radius)) > 0.4 {
            let fade = CABasicAnimation(keyPath: "filters.\(name).inputRadius")
            fade.fromValue = current
            fade.toValue = radius
            fade.duration = GlassFocus.blurDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode = .forwards
            layer.add(fade, forKey: "aetherBlurRadius")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        CATransaction.commit()
    }

    private func removeContentBlur(from layer: CALayer) {
        guard layer.filters != nil || layer.shouldRasterize || stage.layerUsesCoreImageFilters else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "aetherBlurRadius")
        layer.filters = nil
        layer.shouldRasterize = false
        stage.layerUsesCoreImageFilters = false
        CATransaction.commit()
    }

    private func animateBorder(_ focused: Bool) {
        guard let layer = outline.layer else { return }
        let border = focusBorder(focused)
        let width: CGFloat = appliedBroadcast ? (focused ? 2.5 : 2) : border.width
        // borderColor is a CGColor. Animating the presentation layer's color
        // releases a pointer the window server still owns, which crashes in
        // the next autorelease pool drain.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = appliedBroadcast ? Self.broadcastColor.cgColor : border.color.cgColor
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
    }

    func showNotice(_ text: String, action: String) {
        exitBanner.isHidden = false
        exitBanner.setNotice(text, action: action)
        needsLayout = true
    }

    func hideExit() {
        exitBanner.isHidden = true
        needsLayout = true
    }
}

@MainActor
final class PaneHeader: NSView, NSViewToolTipOwner {
    var onFocus: (() -> Void)?
    var onGripDrag: ((NSEvent) -> Void)?
    var onWindowDrag: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onFind: (() -> Void)?
    /// The pane this header belongs to, for the grip's VoiceOver menu.
    var paneID: String? {
        didSet { grip.paneID = paneID }
    }
    private var activity = ""
    private(set) var activityState = ""
    private var cloudNote = ""
    private var broadcasting = false
    private var copyHint: String?
    private(set) var titleText = ""
    private(set) var pathText = ""
    private var focused = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let findButton = NSButton()
    private let grip = PaneGrip()
    private var tone: TextTone = .light
    private var scrim = NSColor.black.withAlphaComponent(0.55)

    private static let gripWidth: CGFloat = 26
    private static let titleX: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = NSColor.white.withAlphaComponent(0.92)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = true
        addSubview(titleField)

        grip.translatesAutoresizingMaskIntoConstraints = true
        addSubview(grip)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close terminal")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.toolTip = "Close terminal"
        closeButton.setAccessibilityLabel("Close terminal")
        closeButton.alphaValue = 0
        addSubview(closeButton)

        findButton.isBordered = false
        findButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
        findButton.imageScaling = .scaleProportionallyDown
        findButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        findButton.target = self
        findButton.action = #selector(findPressed)
        findButton.translatesAutoresizingMaskIntoConstraints = true
        findButton.setAccessibilityLabel("Find in terminal")
        findButton.alphaValue = 0
        addSubview(findButton)
        refreshFindTip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The caption is "title   path". The path is drawn in a quieter tone than the title.
    func setCaption(_ text: String, tone: TextTone) {
        self.tone = tone
        let parts = Self.split(caption: text)
        titleText = parts.title
        pathText = parts.path
        let color: NSColor = tone == .light ? .white : NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let line = NSMutableAttributedString()
        if !parts.title.isEmpty {
            line.append(NSAttributedString(string: parts.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color.withAlphaComponent(0.92),
            ]))
        }
        if !parts.path.isEmpty {
            line.append(NSAttributedString(string: parts.title.isEmpty ? parts.path : "  \(parts.path)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color.withAlphaComponent(0.55),
            ]))
        }
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        titleField.attributedStringValue = line
        titleField.setAccessibilityLabel([parts.title, parts.path].filter { !$0.isEmpty }.joined(separator: ", "))
        closeButton.contentTintColor = color.withAlphaComponent(0.75)
        findButton.contentTintColor = color.withAlphaComponent(0.75)
        refreshFindTip()
        needsDisplay = true
    }

    nonisolated static func split(caption text: String) -> (title: String, path: String) {
        guard let gap = text.range(of: "   ", options: .backwards) else { return ("", text) }
        return (String(text[..<gap.lowerBound]), String(text[gap.upperBound...]))
    }

    private func refreshFindTip() {
        let chord = AppModel.shared.settings.keys.chord(.find)
        findButton.toolTip = chord.key.isEmpty ? "Find" : "Find  \(chord.symbol)"
    }

    /// Called with the pane's focus. Find shows on the focused pane, Close on it or under the pointer.
    func setFindVisible(_ visible: Bool) {
        focused = visible
        refreshButtons()
    }

    private func refreshButtons() {
        findButton.alphaValue = focused ? 1 : 0
        closeButton.alphaValue = focused || hovering ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshButtons()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshButtons()
    }

    func setCloud(_ note: String) {
        cloudNote = note
        needsDisplay = true
        needsLayout = true
    }

    func setBroadcasting(_ on: Bool) {
        guard broadcasting != on else { return }
        broadcasting = on
        needsDisplay = true
        needsLayout = true
    }

    /// "COPY" and a hint while the pane is in copy mode. Nil hides it.
    func setCopyMode(_ hint: String?) {
        guard copyHint != hint else { return }
        copyHint = hint
        needsDisplay = true
        needsLayout = true
    }

    private var copyText: NSAttributedString? {
        guard let copyHint else { return nil }
        let ink = NSColor.black.withAlphaComponent(0.85)
        let text = NSMutableAttributedString(string: "COPY", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: ink])
        text.append(NSAttributedString(string: "  " + copyHint, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: ink]))
        return text
    }

    func setActivity(state: String, message: String) {
        activityState = state
        activity = message
        needsDisplay = true
        needsLayout = true
    }

    func setScrim(_ color: NSColor) {
        scrim = color
        needsDisplay = true
    }

    /// Everything on the right that the title must stay clear of: the Copy and Broadcasting pills and the Cloud note.
    private func rightSide() -> (pill: NSRect?, copy: NSRect?, note: NSRect?, titleRight: CGFloat) {
        var right = bounds.width - 80
        var pill: NSRect?
        if broadcasting {
            let size = Self.pillText.size()
            let frame = NSRect(x: bounds.width - 92 - size.width - 14, y: 5, width: size.width + 14, height: 16)
            pill = frame
            right = frame.minX - 6
        }
        var copy: NSRect?
        if let text = copyText {
            let width = min(ceil(text.size().width) + 14, max(44, (right - Self.titleX) * 0.6))
            let frame = NSRect(x: (pill == nil ? bounds.width - 92 : right) - width, y: 5, width: width, height: 16)
            copy = frame
            right = frame.minX - 6
        }
        var note: NSRect?
        if !cloudNote.isEmpty {
            let width = min(ceil(noteText(ink: .white).size().width) + 2, max(40, (right - Self.titleX) * 0.45))
            let frame = NSRect(x: right - width, y: 7, width: width, height: 14)
            note = frame
            right = frame.minX - 8
        }
        return (pill, copy, note, right)
    }

    private static let pillText = NSAttributedString(string: "Broadcasting", attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .bold),
        .foregroundColor: NSColor.black.withAlphaComponent(0.85),
    ])

    private func noteText(ink: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: cloudNote, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: ink.withAlphaComponent(0.78),
            .paragraphStyle: style,
        ])
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 32, y: 1, width: 24, height: 24)
        findButton.frame = NSRect(x: bounds.width - 56, y: 1, width: 24, height: 24)
        grip.frame = NSRect(x: 0, y: 0, width: Self.gripWidth, height: bounds.height)
        let right = min(rightSide().titleRight, bounds.width - 78)
        titleField.frame = NSRect(x: Self.titleX, y: 3, width: max(0, right - Self.titleX), height: 20)
        removeAllToolTips()
        if !activity.isEmpty, activityState != "idle" { addToolTip(NSRect(x: bounds.width - 78, y: 4, width: 19, height: 19), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        activity
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor = tone == .light ? .white : .black
        scrim.setFill()
        bounds.fill()
        ink.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 1)).fill()
        let dots = ink.withAlphaComponent(0.55)
        dots.setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let dot = NSRect(x: 16 + CGFloat(column) * 5, y: 6 + CGFloat(row) * 5, width: 2.4, height: 2.4)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
        if activityState == "working" || activityState == "blocked" || activityState == "done" || activityState == "error" {
            let color: NSColor
            switch activityState {
            case "blocked": color = tone == .light ? NSColor(srgbRed: 0.96, green: 0.78, blue: 0.45, alpha: 0.95) : NSColor(srgbRed: 0.72, green: 0.47, blue: 0.04, alpha: 0.95)
            case "error": color = tone == .light ? NSColor(srgbRed: 0.95, green: 0.45, blue: 0.42, alpha: 0.95) : NSColor(srgbRed: 0.78, green: 0.17, blue: 0.15, alpha: 0.95)
            case "done": color = tone == .light ? NSColor(srgbRed: 0.55, green: 0.9, blue: 0.7, alpha: 0.95) : NSColor(srgbRed: 0.09, green: 0.55, blue: 0.3, alpha: 0.95)
            default: color = ink.withAlphaComponent(0.92)
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 72, y: 10, width: 7, height: 7)).fill()
        }
        let side = rightSide()
        if let frame = side.pill {
            let size = Self.pillText.size()
            NSColor(srgbRed: 0.99, green: 0.66, blue: 0.2, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            Self.pillText.draw(at: NSPoint(x: frame.minX + 7, y: frame.minY + (frame.height - size.height) / 2))
        }
        if let frame = side.copy, let text = copyText {
            NSColor(srgbRed: 0.45, green: 0.74, blue: 1, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let line = NSMutableAttributedString(attributedString: text)
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            line.draw(in: frame.insetBy(dx: 7, dy: (frame.height - text.size().height) / 2))
        }
        if let frame = side.note {
            noteText(ink: ink).draw(in: frame)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        let local = convert(event.locationInWindow, from: nil)
        if local.x < Self.gripWidth {
            onGripDrag?(event)
            return
        }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(window)
            return
        }
        onWindowDrag?(event)
    }

    /// Follows "Double-click a window's title bar to" in Desktop & Dock settings.
    static func performTitlebarDoubleClick(_ window: NSWindow?) {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: Self.gripWidth, height: bounds.height), cursor: .openHand)
        addCursorRect(NSRect(x: Self.gripWidth, y: 0, width: max(0, bounds.width - 56), height: bounds.height), cursor: .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === findButton, findButton.alphaValue < 0.2 { return self }
        if hit === closeButton, closeButton.alphaValue < 0.2 { return self }
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
    /// Showing a connection notice, whose keys work while the shell is still alive.
    private(set) var notice = false
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

    func setNotice(_ text: String, action: String) {
        lastRan = nil
        notice = true
        label.stringValue = text
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        button.title = action
        closeButton.title = "Close ⎋"
        needsLayout = true
    }

    func setCode(_ code: Int32?) {
        lastRan = nil
        notice = false
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
        notice = false
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
    /// Commands and prompts as the shell integration reports them.
    private(set) var shellState = CommandTracker()
    /// The command line running right now, when the shell reports it.
    var currentCommand: String? { shellState.running?.line }
    /// The shell reports its prompts and commands, so polling the process group is not needed.
    var shellIntegrated: Bool { shellState.active }

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
        chrome = PaneChrome(
            paneID: id,
            font: PaneController.font(size: settings.fontSize, family: settings.fontFamily),
            cursor: PaneController.cursorStyle(settings),
            scrollback: settings.scrollbackLines
        )
        appliedCursor = PaneController.cursorStyle(settings)
        appliedScrollback = settings.scrollbackLines
        PaneController.watchAccessibility()
        refreshGit()
        apply(settings)
        chrome.header.setCaption(caption, tone: settings.text.effective)
        chrome.terminal.processDelegate = DelegateBridge.shared
        DelegateBridge.shared.register(self)
        wireChrome()
    }

    /// Set from Rename Terminal. Titles that programs send are still kept underneath.
    var customTitle: String?

    var caption: String {
        let path = System.displayPath(cwd)
        let git = gitBranch.isEmpty ? path : "\(path) · \(gitBranch)"
        let shown = customTitle ?? title
        if shown.isEmpty { return git }
        return "\(shown)   \(git)"
    }

    private var gitBranch = ""

    private func refreshGit() {
        let next = GitStatus.branch(in: cwd) ?? ""
        guard next != gitBranch else { return }
        gitBranch = next
    }

    var holdsPreview = false
    /// A Cloud terminal saved with this pane last time. Launching attaches to it instead of starting a new one.
    var resumeRemote: String?
    /// The link to this pane's Cloud terminal dropped, but the shell may still be running there.
    private(set) var remoteResumable = false
    private var remoteTicket = 0

    func launch() {
        if holdsPreview { return }
        exited = false
        if AppModel.shared.settings.usesCloud {
            launchRemote()
            return
        }
        // Cloud was turned off. The Cloud terminal keeps running on the server, but this pane
        // lets go of it, so typing reaches the new local shell.
        let attached = chrome.terminal.remoteSession
        if attached != nil || resumeRemote != nil {
            remoteTicket += 1
            remoteResumable = false
            chrome.terminal.remoteSession = nil
            resumeRemote = nil
            if let attached {
                SessionHub.shared.detach(attached)
                chrome.header.setActivity(state: "", message: "")
            }
            AppModel.shared.noteRemote(id, session: nil)
        }
        launchLocal()
    }

    private func launchRemote(attempt: Int = 0) {
        remoteTicket += 1
        let ticket = remoteTicket
        chrome.header.setCloud("Connecting")
        hideNotices()
        if chrome.terminal.process.running {
            chrome.terminal.terminate()
        }
        let term: Terminal = chrome.terminal.terminal
        let cols = term.cols > 1 ? term.cols : 80
        let rows = term.rows > 1 ? term.rows : 24
        let resume = chrome.terminal.remoteSession ?? resumeRemote
        Task { @MainActor in
            do {
                let hub = SessionHub.shared
                var id = ""
                if let resume {
                    // The server replays the screen on attach, so start clean.
                    self.resetRemoteScreen()
                    do {
                        try await hub.attach(id: resume, cols: cols, rows: rows)
                        id = resume
                    } catch SessionError.server(let message) where message == "no such session" {
                        id = ""
                    }
                }
                if id.isEmpty {
                    id = try await hub.create(cwd: "", cols: cols, rows: rows, command: command)
                }
                guard !self.didShutdown, ticket == self.remoteTicket else {
                    if id != resume { hub.close(id) }
                    return
                }
                self.bindRemote(id, cols: cols, rows: rows)
            } catch {
                guard !self.didShutdown, ticket == self.remoteTicket else { return }
                guard attempt < 2, error as? SessionError != .unauthorized else {
                    let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.remoteResumable = (self.chrome.terminal.remoteSession ?? self.resumeRemote) != nil
                    self.chrome.header.setCloud(text)
                    self.chrome.showNotice("Disconnected · \(text)", action: "Reconnect")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
                guard !self.didShutdown, ticket == self.remoteTicket else { return }
                self.launchRemote(attempt: attempt + 1)
            }
        }
    }

    /// Starts showing a Cloud terminal. The size is the one the server was given, so a later change gets sent.
    private func bindRemote(_ id: String, cols: Int, rows: Int) {
        let hub = SessionHub.shared
        if let old = chrome.terminal.remoteSession, old != id {
            hub.close(old)
        }
        hub.track(id, cols: cols, rows: rows)
        chrome.terminal.remoteSession = id
        resumeRemote = nil
        remoteResumable = false
        AppModel.shared.noteRemote(self.id, session: id)
        chrome.header.setCloud(hub.link == .connected ? "Cloud" : hub.link.title)
        hub.onResync(id) { [weak self] in
            self?.resetRemoteScreen()
        }
        hub.onOutput(id) { [weak self] data in
            self?.chrome.terminal.feed(byteArray: ArraySlice([UInt8](data)))
        }
        hub.onStatus(id) { [weak self] state, message in
            self?.chrome.header.setActivity(state: state, message: message)
            if state == "done", message == "exited" {
                self?.remoteResumable = false
                self?.noteExit(0)
            }
        }
        hub.onEvent(id) { [weak self] event in
            guard let self else { return }
            switch event {
            case .disconnected:
                self.remoteResumable = true
                self.chrome.showNotice("Disconnected from Cloud", action: "Reconnect")
            case .restored:
                self.remoteResumable = false
                self.chrome.hideExit()
            case .gone:
                self.remoteResumable = false
                self.chrome.showNotice("This Cloud terminal is gone", action: "Restart")
            }
        }
        hideNotices()
        chrome.terminal.syncRemoteSize()
    }

    /// Hides exit and connection banners, but keeps a restored pane's offer to run its command again.
    private func hideNotices() {
        if chrome.exitBanner.lastRan == nil {
            chrome.hideExit()
        }
    }

    private func resetRemoteScreen() {
        chrome.terminal.terminal.resetToInitialState()
        chrome.terminal.feed(byteArray: [])
    }

    func screenText() -> String {
        let term: Terminal = chrome.terminal.terminal
        let end = Position(col: max(term.cols - 1, 0), row: max(term.rows - 1, 0))
        return term.getText(start: Position(col: 0, row: 0), end: end)
    }

    /// Text from absolute row `since` on, with soft-wrapped rows joined, so a caller can stream output
    /// without repeats. Stops before the cursor's row, which may still grow, unless `final`.
    /// With `toPrompt`, also stops at the last prompt the shell marked, so the prompt is left out.
    /// `next` is where the following call should start; `cursor` is the cursor's absolute row.
    /// With `skipWrapped`, rows that continue the row above `since` (a long command line) are left out.
    func transcript(since: Int?, final: Bool, toPrompt: Bool = false, skipWrapped: Bool = false) -> (text: String, next: Int, cursor: Int) {
        let term: Terminal = chrome.terminal.terminal
        let top = term.buffer.totalLinesTrimmed
        var end = top
        // ponytail: walks the whole scrollback each call; keep a count if reads get hot.
        while term.getScrollInvariantLine(row: end) != nil { end += 1 }
        let cursor = end - term.rows + term.getCursorLocation().y
        var start = max(since ?? cursor, top)
        while skipWrapped, start < cursor, term.getScrollInvariantLine(row: start)?.isWrapped == true { start += 1 }
        var stop = final ? end : cursor
        if toPrompt, let prompt = chrome.terminal.promptRows().last.map({ $0 + top }), prompt >= start {
            stop = min(stop, prompt)
        }
        if final || toPrompt {
            while stop > start, term.getScrollInvariantLine(row: stop - 1)?.translateToString(trimRight: true).isEmpty != false {
                stop -= 1
            }
        }
        guard start < stop else { return ("", start, cursor) }
        var text = ""
        for row in start..<stop {
            guard let line = term.getScrollInvariantLine(row: row) else { break }
            let wraps = term.getScrollInvariantLine(row: row + 1)?.isWrapped ?? false
            text += line.translateToString(trimRight: !wraps, skipNullCellsFollowingWide: true)
            if !wraps || row == stop - 1 && (final || toPrompt) { text += "\n" }
        }
        return (text, stop, cursor)
    }

    func inject(_ bytes: [UInt8]) {
        chrome.terminal.send(source: chrome.terminal, data: bytes[...])
    }

    /// Name the pane after the foreground process so agents can tell tabs apart.
    func syncProcessTitle() {
        guard customTitle == nil, let running = runningCommand() else { return }
        setTitle(ShellIntegration.summary(running.line))
    }

    func agentState(desk: String, focused: Bool) -> [String: Any] {
        let running = runningCommand()?.line
        var row: [String: Any] = [
            "id": id,
            "desk": desk,
            "window": desk,
            "title": customTitle ?? title,
            "cwd": cwd,
            "focused": focused,
            "idle": running == nil && !exited,
            "exited": exited,
            "integrated": shellIntegrated,
            "prompts": shellState.prompts,
        ]
        if let running { row["command"] = running }
        if let code = lastExitCode { row["exitCode"] = Int(code) }
        if let last = shellState.lastFinished {
            row["lastCommand"] = last.line
            if let code = last.exitCode { row["lastStatus"] = Int(code) }
        }
        return row
    }

    func screenshot(to path: String?) -> String? {
        chrome.layoutSubtreeIfNeeded()
        let bounds = chrome.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = chrome.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        chrome.cacheDisplay(in: bounds, to: rep)
        // The pane is see-through and the glass behind it does not render offscreen,
        // so lay it on the theme's own background, or the text lands on nothing.
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        // The context draws in pixels; the PNG keeps the screen's point size.
        let pixels = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        veil.withAlphaComponent(1).setFill()
        pixels.fill()
        rep.draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let terminal = chrome.terminal
        if terminal.isUsingMetalRenderer {
            // Metal frames never reach cacheDisplay's bitmap, so draw the text the CoreGraphics way on top.
            let frame = chrome.convert(terminal.bounds, from: terminal)
            let scale = CGFloat(rep.pixelsWide) / bounds.width
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: frame.minX, y: frame.minY)
            context.cgContext.clip(to: terminal.bounds)
            // SwiftTerm paints cell backgrounds with a copy blend, which would punch holes through the veil without a layer of its own.
            context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            terminal.drawTerminalContents(dirtyRect: terminal.bounds, context: context.cgContext, bufferOffset: terminal.terminal.getTopVisibleRow())
            context.cgContext.endTransparencyLayer()
            context.cgContext.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        canvas.size = rep.size
        guard let png = canvas.representation(using: .png, properties: [:]) else { return nil }
        let dest: URL
        if let path, !path.isEmpty {
            dest = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            dest = FileManager.default.temporaryDirectory.appendingPathComponent("aether-\(id.prefix(8)).png")
        }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    func endRemoteSession() {
        remoteTicket += 1
        remoteResumable = false
        let target = chrome.terminal.remoteSession ?? resumeRemote
        resumeRemote = nil
        chrome.terminal.remoteSession = nil
        if let target {
            SessionHub.shared.close(target)
            AppModel.shared.noteRemote(id, session: nil)
        }
    }

    /// Clears the screen and the scrollback and keeps the line the cursor is on, as ⌘K does in Terminal.app.
    /// A shell sitting at its prompt also gets ⌃L, so it redraws the whole prompt with whatever was typed.
    func clearBuffer() {
        Scrollback.forget(id)
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

    static let cloudBusyPrefix = "A Cloud terminal"

    /// What is running in the foreground, or nil for a shell waiting at its prompt.
    /// A Cloud pane's processes live on the server, so it counts as busy while it reports working or blocked.
    func runningCommand() -> (name: String, line: String)? {
        let view = chrome.terminal
        if view.remoteSession != nil {
            guard !exited else { return nil }
            switch chrome.header.activityState {
            case "working": return ("\(Self.cloudBusyPrefix) is still working", "Cloud terminal")
            case "blocked": return ("\(Self.cloudBusyPrefix) is waiting for an answer", "Cloud terminal")
            default: return nil
            }
        }
        guard !exited, let process = view.process, process.running, process.shellPid > 0 else { return nil }
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
        if let line = currentCommand { return (name, ShellIntegration.summary(line)) }
        return (name, System.commandLine(pid: foreground) ?? name)
    }

    /// Name and path for the tab chip: the foreground job, else the shell.
    func tabProcess() -> (name: String, path: String?) {
        if let running = runningCommand() {
            let view = chrome.terminal
            if view.remoteSession != nil {
                return (running.name, nil)
            }
            if let process = view.process, process.childfd >= 0 {
                let foreground = tcgetpgrp(process.childfd)
                if foreground > 0 {
                    return (running.name, System.processPath(pid: foreground) ?? System.processPath(pid: process.shellPid))
                }
            }
            return (running.name, nil)
        }
        let pid = chrome.terminal.process.shellPid
        let path = System.processPath(pid: pid)
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? URL(fileURLWithPath: System.userShell()).lastPathComponent
        return (name, path)
    }

    /// A restored pane that last ran a command starts as a plain shell and offers to run it again.
    func offerRerun(_ command: String) {
        chrome.showLastRan(command)
    }

    private func runAgain(_ command: String) {
        chrome.hideExit()
        AppModel.shared.forgetLastRan(id)
        windowFocus()
        chrome.terminal.send(txt: command + "\r")
    }

    nonisolated static func closesOnExit(code: Int32?, command: String?, settings: Settings) -> Bool {
        let plain = command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return settings.shellExit == .close && code == 0 && plain
    }

    /// Text saved from this pane last session. The first local launch draws it above the new prompt.
    var restoredScrollback: (text: String, date: Date)?

    private func launchLocal() {
        if let saved = restoredScrollback {
            restoredScrollback = nil
            let cols = chrome.terminal.terminal?.cols ?? 80
            chrome.terminal.feed(text: saved.text + Scrollback.divider(saved.date, cols: cols))
        }
        let shell = System.userShell()
        let directory = FileManager.default.fileExists(atPath: cwd) ? cwd : System.home()
        cwd = directory
        if chrome.terminal.process.running {
            chrome.terminal.terminate()
        }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environment = PaneController.shellEnvironment(pane: id)
        shellState = CommandTracker()
        if trimmed.isEmpty {
            var enabled = ShellIntegration.enabled(setting: AppModel.shared.settings.shellIntegration)
            if enabled, ShellIntegration.shell(for: shell) != nil {
                enabled = ShellIntegration.install()
            }
            let launch = ShellIntegration.plan(shell: shell, environment: environment, root: ShellIntegration.root(), enabled: enabled)
            chrome.terminal.startProcess(executable: shell, args: launch.args, environment: launch.environment, currentDirectory: directory)
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
        let tone = settings.text.effective
        let workspace = NSWorkspace.shared
        let look = TerminalLook(
            settings: settings,
            tone: tone,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        let view = chrome.terminal
        let fontKey = "\(settings.fontFamily)|\(settings.fontSize)|\(settings.lineHeight)"
        if fontKey != appliedFontKey {
            appliedFontKey = fontKey
            view.font = PaneController.font(size: settings.fontSize, family: settings.fontFamily)
            if abs(view.lineSpacing - CGFloat(settings.lineHeight)) > 0.001 {
                view.lineSpacing = CGFloat(settings.lineHeight)
            }
        }
        view.syncRemoteSize()
        // Only on change, so a resize does not undo colors or a cursor the program set for itself.
        if look != appliedLook {
            appliedLook = look
            view.installColors(look.palette.ansi.map(Self.terminalColor))
            let foreground = Self.color(look.palette.foreground)
            view.nativeForegroundColor = foreground
            view.caretColor = Self.color(look.palette.cursor)
            view.selectedTextBackgroundColor = Self.color(look.selection).withAlphaComponent(look.selectionAlpha)
        }
        view.nativeBackgroundColor = .clear
        let cursor = Self.cursorStyle(settings)
        if cursor != appliedCursor {
            appliedCursor = cursor
            view.terminal.setCursorStyle(cursor)
        }
        if settings.scrollbackLines != appliedScrollback {
            appliedScrollback = settings.scrollbackLines
            view.changeScrollback(settings.scrollbackLines)
        }
        view.copyOnSelect = settings.copyOnSelect
        view.gpuRendering = settings.gpuRendering
        view.onBell = { [weak self] in self?.ring() }
        veil = Self.color(look.veil)
        chrome.setBodyShade(veil.withAlphaComponent(look.shade))
        view.appearance = NSAppearance(named: tone == .light ? .darkAqua : .aqua)
        view.optionMode = settings.optionKey
        view.optionAsMetaKey = settings.optionKey == .meta
        view.warnMultilinePaste = settings.warnMultilinePaste
        view.workingDirectory = { [weak self] in self?.cwd ?? System.home() }
        view.onStatus = { [weak self] state, message in
            self?.chrome.header.setActivity(state: state, message: message)
        }
        chrome.header.setScrim(veil.withAlphaComponent(max(look.shade, 0.55)))
        chrome.header.setCaption(caption, tone: tone)
        chrome.layer?.cornerRadius = settings.cornerRadius
    }

    func applyShade(_ shade: Double, settings: Settings) {
        let floor = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? TerminalLook.opaqueShadeFloor : 0
        let shade = max(shade, floor)
        chrome.terminal.nativeBackgroundColor = .clear
        chrome.setBodyShade(veil.withAlphaComponent(shade))
        chrome.header.setScrim(veil.withAlphaComponent(max(shade, 0.55)))
    }

    private var appliedLook: TerminalLook?
    private var appliedFontKey: String?
    private var appliedCursor: CursorStyle?
    private var appliedScrollback: Int?
    private var veil: NSColor = .black
    private var lastBell = Date.distantPast
    private var askedAttention = false

    /// Bells closer together than this ring once, so `yes $'\a'` does not strobe.
    private static let bellGap: TimeInterval = 0.15

    private func ring() {
        let now = Date()
        guard now.timeIntervalSince(lastBell) >= Self.bellGap else { return }
        lastBell = now
        let settings = AppModel.shared.settings
        switch settings.bell {
        case .none:
            return
        case .sound:
            NSSound.beep()
        case .visual:
            chrome.flashBell(tone: settings.text.effective, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        let watched = NSApp.isActive && chrome.isFocused && chrome.window?.isKeyWindow == true
        if watched {
            askedAttention = false
        } else if !askedAttention {
            askedAttention = true
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    static func cursorStyle(_ settings: Settings) -> CursorStyle {
        switch (settings.cursorShape, settings.cursorBlink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    static func color(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    static func terminalColor(_ rgb: RGB) -> SwiftTerm.Color {
        func channel(_ value: Double) -> UInt16 { UInt16((min(max(value, 0), 1) * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(rgb.r), green: channel(rgb.g), blue: channel(rgb.b))
    }

    private static var accessibilityObserver: NSObjectProtocol?

    /// Reduce Transparency and Increase Contrast change the shade, the contrast floor and the focus outline.
    private static func watchAccessibility() {
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let settings = AppModel.shared.settings
                for pane in AppModel.shared.panes.values {
                    pane.apply(settings)
                    pane.chrome.refreshFocusStyle(settings: settings)
                }
            }
        }
    }

    func noteTitle(_ title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // At a reporting shell's prompt the header shows the shell and its directory, whatever the prompt hooks set.
        if shellIntegrated, currentCommand == nil { return }
        self.title = cleaned
        onTitle?(cleaned)
    }

    func noteDirectory(_ directory: String) {
        guard !System.sameDirectory(directory, cwd) else { return }
        cwd = directory
        refreshGit()
        chrome.header.setCaption(caption, tone: AppModel.shared.settings.text.effective)
        onDirectory?(directory)
    }

    func noteReportedDirectory(_ directory: String) {
        reportsDirectory = true
        noteDirectory(directory)
    }

    func noteShellEvent(_ event: ShellEvent) {
        let finished = shellState.apply(event, at: Date())
        if let finished {
            AppModel.shared.shellCommandFinished(id, finished)
        }
        switch event {
        case .command(let line):
            guard shellIntegrated else { return }
            AppModel.shared.shellCommandStarted(id, line: line)
            setTitle(ShellIntegration.summary(line))
        case .prompt:
            if let last = shellState.lastFinished {
                setTitle("Ran \(ShellIntegration.summary(last.line))")
            } else {
                setTitle(shellState.shell ?? URL(fileURLWithPath: System.userShell()).lastPathComponent)
            }
        }
    }

    private func setTitle(_ text: String) {
        guard !text.isEmpty, text != title else { return }
        title = text
        onTitle?(text)
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
        refreshGit()
        chrome.header.setCaption(caption, tone: tone)
    }

    private func wireChrome() {
        chrome.terminal.onUserInput = { [weak self] data in
            guard let self else { return }
            if self.chrome.exitBanner.lastRan != nil, data.contains(13) {
                self.chrome.hideExit()
                AppModel.shared.forgetLastRan(self.id)
            }
            self.onUserInput?(data)
        }
        chrome.terminal.onExitedKey = { [weak self] data in
            guard let self else { return false }
            let notice = self.chrome.exitBanner.notice && !self.chrome.exitBanner.isHidden
            guard self.exited || notice else { return false }
            switch Array(data) {
            case [13], Array("\u{1b}[13u".utf8):
                self.onRestart?()
            case [0x1b], Array("\u{1b}[27u".utf8):
                self.onClose?()
            default:
                // A notice leaves other keys to the terminal, which reconnects when typed into.
                return !notice || self.exited
            }
            return true
        }
        chrome.terminal.onFocus = { [weak self] in
            self?.onFocus?()
        }
        chrome.terminal.onShellEvent = { [weak self] event in
            self?.noteShellEvent(event)
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
                AppModel.shared.forgetLastRan(self.id)
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
            if inheritedNoise.contains(key) || key == "AETHER" || key.hasPrefix("AETHER_") { continue }
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
        let bin = System.supportDirectory().appendingPathComponent("bin").path
        let skill = System.supportDirectory().appendingPathComponent("skill/SKILL.md").path
        if env.contains(where: { $0.hasPrefix("PATH=") }) {
            env = env.map { $0.hasPrefix("PATH=") ? "PATH=\(bin):" + $0.dropFirst(5) : $0 }
        } else {
            env.append("PATH=\(bin):/usr/bin:/bin:/usr/sbin:/sbin")
        }
        env.append("TERM_PROGRAM=Aether")
        env.append("TERM_PROGRAM_VERSION=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        env.append("AETHER=1")
        env.append("AETHER_PANE=\(pane)")
        env.append("AETHER_CONTROL=127.0.0.1:\(AgentDesk.port)")
        env.append("AETHER_AGENT_PLIST=\(System.supportDirectory().appendingPathComponent("agent.plist").path)")
        env.append("AETHER_SKILL=\(skill)")
        return env
    }

    /// The chosen family at its regular weight, else SF Mono, then Menlo. When a Nerd Font is installed,
    /// its icons fill in for glyphs the font lacks, the private-use ones prompts draw with.
    static func font(size: Double, family: String = "") -> NSFont {
        let point = CGFloat(size)
        let base = familyFont(family, size: point) ?? defaultFont(size: point)
        guard let symbols = symbolFamily, !(base.familyName.map(isNerdFont) ?? false) else { return base }
        let cascade = NSFontDescriptor(fontAttributes: [.family: symbols])
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [cascade]]), size: point) ?? base
    }

    private static func defaultFont(size: CGFloat) -> NSFont {
        for name in ["SFMono-Regular", "SF Mono", "Menlo"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Picks the upright regular member of a family, fixed pitch first. A PostScript name works too.
    private static func familyFont(_ family: String, size: CGFloat) -> NSFont? {
        let family = family.trimmingCharacters(in: .whitespaces)
        guard !family.isEmpty else { return nil }
        let manager = NSFontManager.shared
        if let members = manager.availableMembers(ofFontFamily: family), !members.isEmpty {
            let fixed = NSFontTraitMask.fixedPitchFontMask.rawValue
            let slanted = NSFontTraitMask.italicFontMask.rawValue | NSFontTraitMask.boldFontMask.rawValue
            let ranked = members.compactMap { member -> (name: String, score: Int)? in
                guard member.count >= 4, let name = member[0] as? String,
                      let weight = (member[2] as? NSNumber)?.intValue,
                      let traits = (member[3] as? NSNumber)?.uintValue else { return nil }
                var score = abs(weight - 5) * 10
                if traits & slanted != 0 { score += 100 }
                if traits & fixed == 0 { score += 5 }
                return (name, score)
            }
            if let best = ranked.min(by: { $0.score < $1.score }), let font = NSFont(name: best.name, size: size) {
                return font
            }
        }
        return NSFont(name: family, size: size)
    }

    nonisolated private static func isNerdFont(_ family: String) -> Bool {
        family.localizedCaseInsensitiveContains("Nerd Font")
    }

    /// An installed Nerd Font to borrow icons from, Symbols Nerd Font first. Read once per launch.
    private static let symbolFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies
        for name in ["Symbols Nerd Font Mono", "Symbols Nerd Font"] where families.contains(name) {
            return name
        }
        let nerd = families.filter(isNerdFont).sorted()
        return nerd.first { $0.hasSuffix("Nerd Font Mono") } ?? nerd.first { !$0.hasSuffix("Propo") } ?? nerd.first
    }()
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

extension TextTone {
    /// The tone to draw with right now.
    @MainActor var effective: TextTone {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return resolved(darkMode: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
}
