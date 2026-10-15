import AppKit

enum DropTarget: Equatable {
    case onto(pane: String, zone: Zone)
    case detach(origin: CGPoint)
}

@MainActor
final class DeskController: NSWindowController, NSWindowDelegate {
    let deskID: String
    let glass = NSGlassEffectView()
    let canvas = DeskCanvas()
    private var snapping = false
    private var dragMonitor: Any?
    private let highlight = DropHighlight()

    init(deskID: String, frame: NSRect) {
        self.deskID = deskID
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 420, height: 280)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.title = "Aether"
        super.init(window: window)
        window.delegate = self
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = window.contentView?.bounds ?? frame
        glass.style = .clear
        glass.cornerRadius = 20
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        canvas.frame = glass.bounds
        canvas.autoresizingMask = [.width, .height]
        glass.contentView = canvas
        window.contentView = glass
        highlight.isHidden = true
        canvas.addSubview(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func sync() {
        guard let desk = AppModel.shared.desks[deskID] else { return }
        let settings = AppModel.shared.settings
        glass.cornerRadius = settings.cornerRadius
        glass.style = settings.glass == .clear ? .clear : .regular
        canvas.layOut(desk: desk, settings: settings)
        let focused = desk.panes[desk.focusedID]
        let title = focused?.title ?? "Aether"
        window?.title = "\(title) — Aether"
        if window?.isKeyWindow == true {
            focusTerminal(desk.focusedID)
        }
    }

    func focusTerminal(_ paneID: String) {
        guard let window, window.isKeyWindow else { return }
        guard let pane = AppModel.shared.panes[paneID] else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: pane.chrome.terminal), responder !== pane.chrome.terminal {
            return
        }
        if window.firstResponder !== pane.chrome.terminal {
            window.makeFirstResponder(pane.chrome.terminal)
        }
    }

    func showHighlight(paneID: String, zone: Zone) {
        guard let frame = canvas.frameOfPane(paneID) else {
            highlight.isHidden = true
            return
        }
        highlight.frame = Self.highlightFrame(pane: frame, zone: zone)
        highlight.isHidden = false
        canvas.addSubview(highlight)
    }

    func hideHighlight() {
        highlight.isHidden = true
    }

    func contentArea() -> CGRect {
        canvas.contentArea()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppModel.shared.noteKey(deskID)
        guard let desk = AppModel.shared.desks[deskID] else { return }
        focusTerminal(desk.focusedID)
        AppModel.shared.scheduleDirectoryRefresh()
    }

    func windowDidMove(_ notification: Notification) {
        rememberFrame()
        guard !snapping, dragMonitor == nil, NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.finishWindowDrag()
            return event
        }
    }

    func windowDidResize(_ notification: Notification) {
        canvas.frame = glass.bounds
        sync()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrame()
    }

    func windowWillClose(_ notification: Notification) {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
        AppModel.shared.deskWindowClosed(deskID)
    }

    func windowDidResignKey(_ notification: Notification) {
        canvas.refreshFocus()
    }

    private func finishWindowDrag() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
        guard let window, !snapping else {
            rememberFrame()
            return
        }
        let settings = AppModel.shared.settings
        let option = NSEvent.modifierFlags.contains(.option)
        if settings.snapWindows, !option, let screen = window.screen?.visibleFrame {
            let others = AppModel.shared.controllers.values.compactMap { controller -> CGRect? in
                guard controller !== self, let frame = controller.window?.frame else { return nil }
                return frame
            }
            let snapped = Layout.snapFrame(window.frame, others: others, screen: screen, threshold: 12)
            if !nearlyEqual(snapped, window.frame) {
                snapping = true
                window.setFrame(snapped, display: true, animate: false)
                snapping = false
            }
        }
        rememberFrame()
    }

    private func rememberFrame() {
        guard let frame = window?.frame else { return }
        AppModel.shared.noteFrame(deskID, frame)
    }

    func trackDivider(_ grip: DividerGrip, _ start: NSEvent) {
        let origin = start.locationInWindow
        guard let ratio = AppModel.shared.ratio(deskID: deskID, splitID: grip.splitID) else { return }
        let span = max(grip.span, 1)
        while true {
            guard let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: nil, inMode: .eventTracking, dequeue: true) else { continue }
            let now = event.locationInWindow
            let delta: CGFloat = grip.axis == .row ? (now.x - origin.x) : (origin.y - now.y)
            AppModel.shared.setRatio(deskID: deskID, splitID: grip.splitID, ratio: ratio + Double(delta / span))
            if event.type == .leftMouseUp { break }
        }
    }

    func trackPaneDrag(_ paneID: String, _ start: NSEvent) {
        let startPoint = NSEvent.mouseLocation
        let preview = DragPreview(title: AppModel.shared.panes[paneID]?.caption ?? "Terminal")
        preview.orderFrontRegardless()
        var moved = false
        var target: DropTarget?
        AppModel.shared.panes[paneID]?.chrome.alphaValue = 0.45
        defer {
            AppModel.shared.panes[paneID]?.chrome.alphaValue = 1
            preview.orderOut(nil)
            preview.close()
            AppModel.shared.hideHighlights()
        }
        while true {
            guard let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: nil, inMode: .eventTracking, dequeue: true) else { continue }
            let point = NSEvent.mouseLocation
            if hypot(point.x - startPoint.x, point.y - startPoint.y) > 5 { moved = true }
            preview.place(at: point)
            target = AppModel.shared.dropTarget(at: point, dragging: paneID)
            AppModel.shared.showHighlight(target, dragging: paneID)
            if event.type == .leftMouseUp { break }
        }
        guard moved, let target else { return }
        AppModel.shared.performDrop(paneID: paneID, target: target, from: deskID)
    }

    static func highlightFrame(pane: CGRect, zone: Zone) -> CGRect {
        switch zone {
        case .left:
            return CGRect(x: pane.minX, y: pane.minY, width: pane.width * 0.5, height: pane.height)
        case .right:
            return CGRect(x: pane.midX, y: pane.minY, width: pane.width * 0.5, height: pane.height)
        case .bottom:
            return CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height * 0.5)
        case .top:
            return CGRect(x: pane.minX, y: pane.midY, width: pane.width, height: pane.height * 0.5)
        case .center:
            return pane.insetBy(dx: 6, dy: 6)
        }
    }

    private func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

@MainActor
final class DeskCanvas: NSView {
    private var dividers: [DividerGrip] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func contentArea() -> CGRect {
        guard let window else { return bounds.insetBy(dx: 8, dy: 8) }
        let layout = convert(window.contentLayoutRect, from: nil)
        let top = max(8, bounds.maxY - layout.maxY + 4)
        return CGRect(x: 8, y: 8, width: max(40, bounds.width - 16), height: max(40, bounds.height - top - 8))
    }

    func layOut(desk: Desk, settings: Settings) {
        let area = contentArea()
        let placed: (panes: [PlacedPane], dividers: [PlacedDivider])
        if let maximized = desk.maximizedID, desk.layout.panes.contains(maximized) {
            let inset = area.insetBy(dx: CGFloat(settings.gap) / 2, dy: CGFloat(settings.gap) / 2)
            placed = ([PlacedPane(id: maximized, frame: inset)], [])
        } else {
            placed = Layout.place(desk.layout, in: area, gap: CGFloat(settings.gap))
        }

        let live = Set(desk.layout.panes)
        for subview in subviews {
            guard let chrome = subview as? PaneChrome, !live.contains(chrome.paneID) else { continue }
            chrome.removeFromSuperview()
        }

        var visible = Set<String>()
        for item in placed.panes {
            guard let pane = AppModel.shared.panes[item.id] else { continue }
            if pane.chrome.superview !== self {
                addSubview(pane.chrome)
            }
            pane.chrome.frame = item.frame
            pane.chrome.isHidden = false
            pane.refreshCaption(tone: settings.text)
            pane.chrome.setFocused(item.id == desk.focusedID && window?.isKeyWindow != false)
            wire(pane)
            visible.insert(item.id)
        }
        for id in desk.layout.panes where !visible.contains(id) {
            AppModel.shared.panes[id]?.chrome.isHidden = true
        }

        dividers.forEach { $0.removeFromSuperview() }
        dividers = placed.dividers.map { item in
            let grip = DividerGrip(frame: item.frame)
            grip.axis = item.axis
            grip.splitID = item.splitID
            grip.span = item.span
            grip.onDrag = { [weak self] event, grip in
                guard let controller = self?.window?.windowController as? DeskController else { return }
                controller.trackDivider(grip, event)
            }
            addSubview(grip)
            return grip
        }
    }

    func frameOfPane(_ id: String) -> CGRect? {
        guard let chrome = AppModel.shared.panes[id]?.chrome, chrome.superview === self, !chrome.isHidden else { return nil }
        return chrome.frame
    }

    func refreshFocus() {
        guard let deskID = (window?.windowController as? DeskController)?.deskID,
              let desk = AppModel.shared.desks[deskID] else { return }
        let key = window?.isKeyWindow == true
        for id in desk.layout.panes {
            AppModel.shared.panes[id]?.chrome.setFocused(key && id == desk.focusedID)
        }
    }

    private func wire(_ pane: PaneController) {
        let id = pane.id
        pane.onFocus = {
            AppModel.shared.focus(pane: id)
        }
        pane.onClose = {
            AppModel.shared.closePane(id)
        }
        pane.onRestart = {
            AppModel.shared.restart(id)
        }
        pane.onTitle = { _ in
            AppModel.shared.refreshChrome(for: id)
        }
        pane.onDirectory = { _ in
            AppModel.shared.refreshChrome(for: id)
        }
        pane.onExit = { code in
            AppModel.shared.noteExit(id, code: code)
        }
        pane.onUserInput = { data in
            AppModel.shared.broadcast(from: id, data: data)
        }
        pane.onGripDrag = { [weak self] event in
            guard let controller = self?.window?.windowController as? DeskController else { return }
            controller.trackPaneDrag(id, event)
        }
        pane.onWindowDrag = { [weak self] event in
            self?.window?.performDrag(with: event)
        }
    }
}

@MainActor
final class DragPreview: NSWindow {
    init(title: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = true
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        glass.style = .regular
        glass.cornerRadius = 12
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 12, y: 12, width: 216, height: 20)
        let host = NSView(frame: glass.bounds)
        host.addSubview(label)
        glass.contentView = host
        contentView = glass
    }

    func place(at screenPoint: NSPoint) {
        setFrameOrigin(NSPoint(x: screenPoint.x + 12, y: screenPoint.y - 28))
    }
}
