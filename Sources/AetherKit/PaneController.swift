import AppKit
import SwiftTerm

@MainActor
final class AetherTerminal: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        onUserInput?(data)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PaneChrome: NSView {
    let paneID: String
    let header = PaneHeader()
    let terminal: AetherTerminal
    let exitBanner = ExitBanner()
    private let outline = PassthroughView()

    init(paneID: String, font: NSFont) {
        self.paneID = paneID
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.cursorStyle = .steadyBar
        options.termName = "xterm-256color"
        terminal = AetherTerminal(frame: .zero, font: font, options: options)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        header.translatesAutoresizingMaskIntoConstraints = true
        terminal.translatesAutoresizingMaskIntoConstraints = true
        exitBanner.translatesAutoresizingMaskIntoConstraints = true
        outline.translatesAutoresizingMaskIntoConstraints = true
        addSubview(terminal)
        addSubview(header)
        addSubview(exitBanner)
        addSubview(outline)
        exitBanner.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 34
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        let bannerHeight: CGFloat = exitBanner.isHidden ? 0 : 36
        exitBanner.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 28)
        terminal.frame = NSRect(x: 0, y: bannerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight - bannerHeight))
        outline.frame = bounds
        outline.layer?.cornerRadius = layer?.cornerRadius ?? 12
    }

    func setFocused(_ focused: Bool) {
        outline.layer?.borderWidth = focused ? 1 : 0.5
        outline.layer?.borderColor = NSColor.white.withAlphaComponent(focused ? 0.72 : 0.16).cgColor
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

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCaption(_ text: String, tone: TextTone) {
        self.tone = tone
        titleField.stringValue = text
        let color: NSColor = tone == .light ? .white : NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1)
        titleField.textColor = color.withAlphaComponent(0.92)
        closeButton.contentTintColor = color.withAlphaComponent(0.75)
        needsDisplay = true
    }

    func setScrim(_ color: NSColor) {
        scrim = color
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 30, y: 5, width: 24, height: 24)
        titleField.frame = NSRect(x: 28, y: 7, width: max(0, bounds.width - 64), height: 20)
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

    @objc private func closePressed() {
        onClose?()
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
        if trimmed.isEmpty {
            chrome.terminal.startProcess(executable: shell, args: ["-l"], currentDirectory: directory)
        } else {
            chrome.terminal.startProcess(executable: shell, args: ["-lc", trimmed], currentDirectory: directory)
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
        chrome.header.setScrim(veil.withAlphaComponent(max(settings.shade, 0.55)))
        chrome.header.setCaption(caption, tone: settings.text)
        chrome.layer?.cornerRadius = min(14, settings.cornerRadius - 4)
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
        chrome.exitBanner.onRestart = { [weak self] in
            self?.onRestart?()
        }
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
