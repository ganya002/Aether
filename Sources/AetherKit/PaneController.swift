import AppKit
import SwiftTerm

@MainActor
final class AetherTerminal: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    var workingDirectory: () -> String = { System.home() }

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropPaths(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = dropPaths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        insertText(paths.map(ShellPath.quote).joined(separator: " "), replacementRange: NSRange(location: 0, length: 0))
        return true
    }

    private func dropPaths(from pasteboard: NSPasteboard) -> [String] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        }
        guard let image = NSImage(pasteboard: pasteboard), let path = Self.stash(image) else { return [] }
        return [path]
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

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        onUserInput?(data)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    let header = PaneHeader()
    let terminal: AetherTerminal
    let exitBanner = ExitBanner()
    private let clip = NSView()
    private let outline = PassthroughView()
    private let rest = PassthroughView()
    private var blur: FrostView?
    private var appliedFocus: Bool?
    private var appliedRest: FocusRest?
    private var appliedTone: TextTone?

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
        clip.layer?.cornerRadius = 12
        rest.wantsLayer = true
        rest.layer?.backgroundColor = NSColor.black.cgColor
        rest.alphaValue = 0
        for view in [clip, terminal, header, exitBanner, rest, outline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        addSubview(clip)
        clip.addSubview(terminal)
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
        let radius = layer?.cornerRadius ?? 12
        clip.frame = bounds
        clip.layer?.cornerRadius = radius
        let headerHeight: CGFloat = 34
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        let bannerHeight: CGFloat = exitBanner.isHidden ? 0 : 36
        exitBanner.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 28)
        terminal.frame = NSRect(x: 0, y: bannerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight - bannerHeight))
        rest.frame = bounds
        blur?.frame = bounds
        outline.frame = bounds.insetBy(dx: 1, dy: 1)
        outline.layer?.cornerRadius = max(0, radius - 1)
    }

    func setFocused(_ focused: Bool, settings: Settings) {
        if appliedFocus == focused, appliedRest == settings.focusRest, appliedTone == settings.text { return }
        let animate = appliedFocus != nil
        appliedFocus = focused
        appliedRest = settings.focusRest
        appliedTone = settings.text
        let dim: CGFloat = focused || settings.focusRest != .dim ? 0 : (settings.text == .light ? 0.22 : 0.12)
        let showBlur = !focused && settings.focusRest == .blur
        if showBlur, blur == nil {
            let view = FrostView(frame: bounds)
            view.alphaValue = 0
            clip.addSubview(view, positioned: .below, relativeTo: outline)
            blur = view
        }
        let apply = {
            self.rest.alphaValue = dim
            self.blur?.alphaValue = showBlur ? 1 : 0
            self.header.setFindVisible(focused)
        }
        if animate {
            animateBorder(focused)
            Motion.group(Motion.snap) { apply() }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.outline.layer?.borderWidth = focused ? 2 : 0
            self.outline.layer?.borderColor = NSColor.white.withAlphaComponent(focused ? 0.72 : 0).cgColor
            apply()
            CATransaction.commit()
        }
        if !showBlur, let blur {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.snap) { [weak self] in
                guard let self, self.appliedRest != .blur || self.appliedFocus == true else { return }
                blur.removeFromSuperview()
                if self.blur === blur { self.blur = nil }
            }
        }
    }

    private func animateBorder(_ focused: Bool) {
        guard let layer = outline.layer else { return }
        let width: CGFloat = focused ? 2 : 0
        // borderColor is a CGColor. Animating the presentation layer's color
        // releases a pointer the window server still owns, which crashes in
        // the next autorelease pool drain.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = NSColor.white.withAlphaComponent(focused ? 0.72 : 0).cgColor
        CATransaction.commit()
        let widthAnim = CABasicAnimation(keyPath: "borderWidth")
        widthAnim.fromValue = layer.presentation()?.borderWidth ?? layer.borderWidth
        widthAnim.toValue = width
        widthAnim.duration = Motion.snap
        widthAnim.timingFunction = Motion.ease()
        layer.borderWidth = width
        layer.add(widthAnim, forKey: "borderWidth")
    }

    func showExit(code: Int32?) {
        exitBanner.isHidden = false
        exitBanner.setCode(code)
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

    func setScrim(_ color: NSColor) {
        scrim = color
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 30, y: 5, width: 24, height: 24)
        findButton.frame = NSRect(x: bounds.width - 56, y: 5, width: 24, height: 24)
        titleField.frame = NSRect(x: 28, y: 7, width: max(0, bounds.width - 92), height: 20)
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
                let dot = NSRect(x: 10 + CGFloat(column) * 5, y: 11 + CGFloat(row) * 5, width: 2.4, height: 2.4)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
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
    private let label = NSTextField(labelWithString: "Process exited")
    private let button = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        button.isBordered = false
        button.title = "Restart"
        button.contentTintColor = .white
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = #selector(restart)
        button.translatesAutoresizingMaskIntoConstraints = true
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCode(_ code: Int32?) {
        if let code {
            label.stringValue = "Exited \(code)"
        } else {
            label.stringValue = "Process stopped"
        }
    }

    override func layout() {
        label.frame = NSRect(x: 10, y: 4, width: max(0, bounds.width - 90), height: 20)
        button.frame = NSRect(x: bounds.width - 74, y: 2, width: 66, height: 24)
    }

    @objc private func restart() {
        onRestart?()
    }
}

@MainActor
final class FrostView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        material = .hudWindow
        state = .active
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
        chrome.terminal.optionAsMetaKey = false
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

    func launch() {
        let shell = System.userShell()
        let directory = FileManager.default.fileExists(atPath: cwd) ? cwd : System.home()
        cwd = directory
        if chrome.terminal.process.running {
            chrome.terminal.terminate()
        }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environment = PaneController.shellEnvironment()
        if trimmed.isEmpty {
            chrome.terminal.startProcess(executable: shell, args: ["-l"], environment: environment, currentDirectory: directory)
        } else {
            chrome.terminal.startProcess(executable: shell, args: ["-lc", trimmed], environment: environment, currentDirectory: directory)
        }
        chrome.hideExit()
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
        chrome.terminal.nativeBackgroundColor = veil.withAlphaComponent(settings.shade)
        chrome.terminal.selectedTextBackgroundColor = foreground.withAlphaComponent(0.22)
        chrome.terminal.appearance = NSAppearance(named: settings.text == .light ? .darkAqua : .aqua)
        chrome.terminal.workingDirectory = { [weak self] in self?.cwd ?? System.home() }
        chrome.header.setScrim(veil.withAlphaComponent(max(settings.shade, 0.55)))
        chrome.header.setCaption(caption, tone: settings.text)
        chrome.layer?.cornerRadius = min(14, settings.cornerRadius - 4)
    }

    func applyShade(_ shade: Double, settings: Settings) {
        let veil: NSColor = settings.text == .light ? .black : .white
        chrome.terminal.nativeBackgroundColor = veil.withAlphaComponent(shade)
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

    func noteExit(_ code: Int32?) {
        chrome.showExit(code: code)
        onExit?(code)
    }

    func refreshCaption(tone: TextTone) {
        chrome.header.setCaption(caption, tone: tone)
    }

    private func wireChrome() {
        chrome.terminal.onUserInput = { [weak self] data in
            self?.onUserInput?(data)
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

    static func shellEnvironment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let current = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "SSH_AUTH_SOCK"] {
            guard let value = current[key] else { continue }
            env.removeAll { $0.hasPrefix("\(key)=") }
            env.append("\(key)=\(value)")
        }
        if let lang = current["LANG"], lang.uppercased().contains("UTF-8") {
            env.removeAll { $0.hasPrefix("LANG=") }
            env.append("LANG=\(lang)")
        }
        env.append("TERM_PROGRAM=Aether")
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

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

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
                DelegateBridge.shared.pane(for: terminal)?.noteDirectory(directory)
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
