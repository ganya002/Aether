import AppKit

/// The chips in the titlebar, next to the traffic lights: one per workspace tab, then +.
@MainActor
final class WorkspaceTabStrip: NSView {
    var deskID = ""
    private var chips: [WorkspaceTabChip] = []
    private let plus = WorkspaceTabPlus()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        plus.target = self
        plus.action = #selector(addTab)
        addSubview(plus)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Workspace tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func attach(to window: NSWindow?, dropdown: Bool) {
        guard let window, !dropdown,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview else {
            removeFromSuperview()
            isHidden = true
            return
        }
        isHidden = false
        if superview !== titlebar {
            titlebar.addSubview(self, positioned: .below, relativeTo: close)
        }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0)?.frame.maxX }
        let leading = (buttons.max() ?? 70) + 10
        let height = titlebar.bounds.height
        frame = NSRect(x: leading, y: 0, width: max(48, titlebar.bounds.width - leading - 8), height: height)
    }

    func reload(_ desk: Desk) {
        let items = desk.tabs.map { tab -> WorkspaceTabChip.Item in
            let liveTitle = AppModel.shared.panes[tab.focusedID]?.customTitle
                ?? AppModel.shared.panes[tab.focusedID]?.title
                ?? tab.title(from: desk.panes)
            return WorkspaceTabChip.Item(
                id: tab.id,
                title: liveTitle,
                selected: tab.id == desk.activeTabID,
                icons: WorkspaceTabStrip.icons(for: tab),
                closable: desk.tabs.count > 1
            )
        }
        while chips.count < items.count {
            let chip = WorkspaceTabChip()
            chip.onSelect = { [weak self] id in
                guard let self else { return }
                AppModel.shared.selectTab(id, in: self.deskID)
            }
            chip.onClose = { [weak self] id in
                guard let self else { return }
                AppModel.shared.closeTab(id, in: self.deskID)
            }
            chip.onRename = { [weak self] id in
                guard let self else { return }
                WorkspaceTabStrip.rename(tab: id, in: self.deskID)
            }
            addSubview(chip)
            chips.append(chip)
        }
        while chips.count > items.count {
            chips.removeLast().removeFromSuperview()
        }
        for (chip, item) in zip(chips, items) {
            chip.item = item
        }
        layoutChips()
    }

    override func layout() {
        super.layout()
        layoutChips()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        return hit
    }

    private func layoutChips() {
        let height = min(24, max(18, bounds.height - 6))
        let y = max(0, (bounds.height - height) / 2)
        let plusWidth: CGFloat = height
        var x: CGFloat = 0
        let gap: CGFloat = 6
        let budget = max(0, bounds.width - plusWidth - 8)
        let count = max(chips.count, 1)
        let fitted = (budget - gap * CGFloat(count - 1)) / CGFloat(count)
        let maxEach = min(176, max(24, fitted))
        for chip in chips {
            let width = min(chip.preferredWidth(height: height), maxEach)
            chip.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + gap
        }
        plus.frame = NSRect(x: max(0, bounds.width - plusWidth), y: y, width: plusWidth, height: height)
    }

    @objc private func addTab() {
        AppModel.shared.newTab(in: deskID)
    }

    static func rename(tab id: String, in deskID: String) {
        guard let desk = AppModel.shared.desks[deskID],
              let tab = desk.tabs.first(where: { $0.id == id }),
              let window = AppModel.shared.controllers[deskID]?.window,
              window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave it empty to use the focused terminal's title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tab.name ?? ""
        field.placeholderString = tab.title(from: desk.panes)
        field.setAccessibilityLabel("Tab name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                AppModel.shared.renameTab(id, in: deskID, to: field.stringValue)
            }
        }
    }

    static func icons(for tab: WorkspaceTab) -> [NSImage] {
        var images: [NSImage] = []
        var seen = Set<String>()
        for id in Layout.visualIDs(tab.layout) {
            guard let pane = AppModel.shared.panes[id] else { continue }
            let process = pane.tabProcess()
            let key = process.path ?? process.name
            guard seen.insert(key).inserted else { continue }
            images.append(ProcessIcon.image(name: process.name, path: process.path))
            if images.count == 3 { break }
        }
        return images
    }
}

@MainActor
private final class WorkspaceTabChip: NSView {
    struct Item {
        var id: String
        var title: String
        var selected: Bool
        var icons: [NSImage]
        var closable: Bool
    }

    var item = Item(id: "", title: "", selected: false, icons: [], closable: false) {
        didSet { needsDisplay = true; setAccessibilityValue(item.title) }
    }
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    private var hover = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace tab")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func preferredWidth(height: CGFloat) -> CGFloat {
        let icon = iconsWidth(height: height)
        let label = (item.title as NSString).size(withAttributes: [.font: font]).width
        let close: CGFloat = (item.closable && (item.selected || hover)) ? 16 : 0
        return ceil(7 + icon + (icon > 0 ? 5 : 0) + min(label, 118) + close + 8)
    }

    private var font: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    private func iconsWidth(height: CGFloat) -> CGFloat {
        let size = height - 8
        let count = CGFloat(item.icons.count)
        guard count > 0 else { return 0 }
        return size + max(0, count - 1) * (size - 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = item.selected
        let fill = selected ? 0.22 : (hover || pressed ? 0.12 : 0.05)
        let stroke = selected ? 0.34 : 0.12
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(fill).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(stroke).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x: CGFloat = 7
        let iconSize = bounds.height - 8
        let iconY = (bounds.height - iconSize) / 2
        for (index, image) in item.icons.enumerated() {
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            ProcessIcon.draw(image, in: rect, emphasized: selected || hover)
            x += index == item.icons.count - 1 ? iconSize + 5 : iconSize - 6
        }
        let closeSpace: CGFloat = (item.closable && (selected || hover)) ? 16 : 0
        let labelRect = NSRect(x: x, y: 0, width: max(8, bounds.width - x - 8 - closeSpace), height: bounds.height)
        let color = NSColor.labelColor.withAlphaComponent(selected ? 0.92 : 0.62)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (item.title as NSString).draw(in: labelRect.insetBy(dx: 0, dy: (bounds.height - 14) / 2), withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        if item.closable, selected || hover {
            let closeRect = NSRect(x: bounds.width - 16, y: (bounds.height - 10) / 2, width: 10, height: 10)
            let xPath = NSBezierPath()
            xPath.move(to: NSPoint(x: closeRect.minX + 1.5, y: closeRect.minY + 1.5))
            xPath.line(to: NSPoint(x: closeRect.maxX - 1.5, y: closeRect.maxY - 1.5))
            xPath.move(to: NSPoint(x: closeRect.maxX - 1.5, y: closeRect.minY + 1.5))
            xPath.line(to: NSPoint(x: closeRect.minX + 1.5, y: closeRect.maxY - 1.5))
            xPath.lineWidth = 1.2
            xPath.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.7).setStroke()
            xPath.stroke()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        pressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        if event.clickCount == 2 {
            onRename?(item.id)
            pressed = false
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pressed = false
        needsDisplay = true
        guard bounds.contains(local) else { return }
        if item.closable, local.x > bounds.width - 18 {
            onClose?(item.id)
            return
        }
        onSelect?(item.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab", action: #selector(rename), keyEquivalent: "")
        if item.closable {
            menu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
        }
        for entry in menu.items { entry.target = self }
        return menu
    }

    @objc private func rename() { onRename?(item.id) }
    @objc private func closeTab() { onClose?(item.id) }
}

@MainActor
private final class WorkspaceTabPlus: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        imagePosition = .imageOnly
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.55)
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("New tab")
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
}

enum ProcessIcon {
    static func image(name: String, path: String?) -> NSImage {
        if let path, let app = bundle(containing: path) {
            return NSWorkspace.shared.icon(forFile: app)
        }
        let token = name.lowercased()
        if shells.contains(token) {
            return symbol(name)
        }
        if let identifier = bundleID(token),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let applications = "/Applications/\(name).app"
        if FileManager.default.fileExists(atPath: applications) {
            return NSWorkspace.shared.icon(forFile: applications)
        }
        if let path, FileManager.default.fileExists(atPath: path), bundle(containing: path) != nil {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return symbol(name)
    }

    static func draw(_ image: NSImage, in rect: NSRect, emphasized: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(ovalIn: rect)
        path.addClip()
        NSColor.white.withAlphaComponent(emphasized ? 0.16 : 0.08).setFill()
        path.fill()
        image.draw(in: rect.insetBy(dx: 0.5, dy: 0.5), from: .zero, operation: .sourceOver, fraction: emphasized ? 1 : 0.9)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(emphasized ? 0.4 : 0.2).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.4, dy: 0.4))
        ring.lineWidth = 0.8
        ring.stroke()
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "nu", "pwsh"]

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: name) ?? NSImage()
    }

    static func bundle(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func bundleID(_ name: String) -> String? {
        switch name {
        case "node", "nodejs", "npm", "npx", "yarn", "pnpm": "com.nodejs.nodejs"
        case "claude", "claude-code": "com.anthropic.claudefordesktop"
        case "cursor", "cursor-agent": "com.todesktop.230313mzl4w4u92"
        case "code", "code-insiders": "com.microsoft.VSCode"
        case "docker", "com.docker.cli", "docker-compose": "com.docker.docker"
        case "python", "python3": "org.python.python"
        case "bun": "com.oven-sh.bun"
        case "fish": "com.ridiculousfish.fishapp"
        case "iterm2", "iterm": "com.googlecode.iterm2"
        case "ghostty": "com.mitchellh.ghostty"
        case "codex": "com.openai.chat"
        default: nil
        }
    }
}
