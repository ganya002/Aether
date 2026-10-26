import AppKit
import QuartzCore
import SwiftTerm

enum Motion {
    /// Fast out, soft landing. Used for presses and focus.
    static func ease() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.28, 1)
    }

    static let snap: TimeInterval = 0.34
    static let close: TimeInterval = 0.22
    static let frostIn: TimeInterval = 0.32
    static let frostOut: TimeInterval = 0.36
    static let reveal: TimeInterval = 0.42

    static func group(_ duration: TimeInterval, _ changes: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = ease()
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: done)
    }

    static func fade(_ layer: CALayer?, to opacity: Float, key: String) {
        guard let layer else { return }
        let spring = CASpringAnimation(keyPath: "opacity")
        spring.fromValue = layer.presentation()?.opacity ?? layer.opacity
        spring.toValue = opacity
        spring.mass = 0.55
        spring.stiffness = 340
        spring.damping = 28
        spring.duration = min(max(spring.settlingDuration, 0.28), 0.5)
        spring.timingFunction = ease()
        layer.add(spring, forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }
}

enum DropTarget: Equatable {
    case onto(pane: String, zone: Zone)
    case detach(origin: CGPoint, cursor: CGPoint)
    /// Over a window that does not accept panes (the dropdown).
    case refused(desk: String)
}

@MainActor
final class DeskController: NSWindowController, NSWindowDelegate {
    let deskID: String
    let glass = NSGlassEffectView()
    let canvas = DeskCanvas()
    private var snapping = false
    private var dragMonitor: Any?
    private let highlight = DropHighlight()
    private var liveResizing = false
    private var settlingResize = false
    private var acceptingClose = false
    private var dropdownGeneration = 0
    private var dropdownSize: CGSize?
    private var dropdownAnimating = false
    private var dragWatch: Timer?
    private var fullScreenTransition = false
    private var lastDividerSync: CFTimeInterval = 0

    // TODO: move to Settings (dropdownHeightPercent, dropdownHideOnFocusLoss) once the settings owner adds them.
    static let dropdownHeightFraction: CGFloat = 0.44
    static let dropdownHidesOnFocusLoss = true

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
        glass.style = .regular
        glass.cornerRadius = 20
        glass.enableInteractiveGlass()
        canvas.frame = glass.bounds
        canvas.autoresizingMask = [.width, .height]
        glass.contentView = canvas
        GlassPanel.mount(glass, on: window, radius: 20)
        highlight.isHidden = true
        canvas.addSubview(highlight)
    }

    func showUpdateGauge() -> UpdateVeil {
        if let veil = canvas.subviews.compactMap({ $0 as? UpdateVeil }).first {
            canvas.addSubview(veil)
            return veil
        }
        let veil = UpdateVeil(frame: canvas.bounds)
        veil.autoresizingMask = [.width, .height]
        canvas.addSubview(veil)
        veil.reveal()
        return veil
    }

    func hideUpdateGauge() {
        for case let veil as UpdateVeil in canvas.subviews {
            veil.removeFromSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func sync(animated: Bool = false) {
        guard let desk = AppModel.shared.desks[deskID] else { return }
        let settings = AppModel.shared.settings
        glass.cornerRadius = settings.cornerRadius
        glass.layer?.cornerRadius = settings.cornerRadius
        let frosted = liveResizing || settlingResize || settings.glass == .regular
        glass.style = frosted ? .regular : .clear
        canvas.layOut(desk: desk, settings: settings, animated: animated && !liveResizing)
        let focused = desk.panes[desk.focusedID]
        let title = focused?.title ?? "Aether"
        window?.title = "\(title) — Aether"
        if window?.isKeyWindow == true {
            focusTerminal(desk.focusedID)
        }
    }

    func presentAnimated() {
        guard let window else { return }
        let target = window.frame
        let intro = target.insetBy(dx: target.width * 0.022, dy: target.height * 0.028)
        window.setFrame(intro, display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        Motion.group(Motion.reveal, {
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }, done: { [weak self] in
            self?.sync()
        })
    }

    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Top-center of `screen`, hanging from the menu bar.
    static func dropdownFrame(on screen: NSScreen?, size: CGSize? = nil) -> CGRect {
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(size?.width ?? 980, visible.width - 36)
        let height = min(size?.height ?? min(460, max(320, visible.height * dropdownHeightFraction)), visible.height - 16)
        return CGRect(x: visible.midX - width / 2, y: visible.maxY - height, width: width, height: height)
    }

    func presentDropdown() {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        let target = Self.dropdownFrame(on: Self.screenUnderMouse(), size: dropdownSize)
        dropdownGeneration += 1
        let generation = dropdownGeneration
        dropdownAnimating = true
        // Mid-dismiss, turn around from where it is; otherwise slide down from the top edge.
        if !window.isVisible || window.alphaValue < 0.05 {
            window.alphaValue = 0
            window.setFrame(target.offsetBy(dx: 0, dy: min(24, target.height)), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Motion.group(Motion.snap, {
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }, done: { [weak self] in
            guard let self, self.dropdownGeneration == generation else { return }
            self.dropdownAnimating = false
        })
    }

    func dismissDropdown(restoreFocus: Bool) {
        guard let window else { return }
        dropdownGeneration += 1
        let generation = dropdownGeneration
        dropdownAnimating = true
        let frame = window.frame
        Motion.group(Motion.close, {
            window.animator().alphaValue = 0
            window.animator().setFrame(frame.offsetBy(dx: 0, dy: 12), display: true)
        }, done: { [weak self] in
            guard let self, let window = self.window, self.dropdownGeneration == generation else { return }
            self.dropdownAnimating = false
            window.orderOut(nil)
            AppModel.shared.noteDropdownHidden(self.deskID, restoreFocus: restoreFocus)
        })
    }

    private var isDropdown: Bool {
        AppModel.shared.desks[deskID]?.dropdown == true
    }

    /// The frame worth saving: nil while fullscreen or mid-animation.
    var restorableFrame: CGRect? {
        guard let window, !fullScreenTransition, !window.styleMask.contains(.fullScreen), !acceptingClose else { return nil }
        return window.frame
    }

    func flashLayout(_ title: String) {
        canvas.flash(title)
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
        canvas.refreshFocus()
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
        // The mouse-up can land outside the app; never leave the monitor behind.
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
                self?.finishWindowDrag()
            }
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        liveResizing = true
        settlingResize = false
        canvas.frame = glass.bounds
        glass.style = .regular
        canvas.beginResizeDim(settings: AppModel.shared.settings)
    }

    func windowDidResize(_ notification: Notification) {
        canvas.frame = glass.bounds
        sync()
        if liveResizing {
            showGridSize()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        liveResizing = false
        settlingResize = true
        let settings = AppModel.shared.settings
        for id in AppModel.shared.desks[deskID]?.layout.panes ?? [] {
            AppModel.shared.panes[id]?.apply(settings)
        }
        canvas.endResizeDim { [weak self] in
            guard let self, !self.liveResizing else { return }
            self.settlingResize = false
            let settings = AppModel.shared.settings
            self.glass.style = settings.glass == .clear ? .clear : .regular
        }
        if isDropdown, !dropdownAnimating, let size = window?.frame.size {
            dropdownSize = size
        }
        rememberFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTransition = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        rememberFrame()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransition = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if acceptingClose { return true }
        acceptingClose = true
        AppModel.shared.noteClosing(deskID)
        Motion.group(Motion.close, {
            sender.animator().alphaValue = 0
            let frame = sender.frame
            sender.animator().setFrame(frame.insetBy(dx: frame.width * 0.035, dy: frame.height * 0.035), display: true)
        }, done: {
            sender.close()
        })
        return false
    }

    func windowWillClose(_ notification: Notification) {
        stopWatchingWindowDrag()
        AppModel.shared.deskWindowClosed(deskID)
    }

    func windowDidResignKey(_ notification: Notification) {
        canvas.refreshFocus()
        guard isDropdown, Self.dropdownHidesOnFocusLoss else { return }
        // Wait a turn so the new key window is known. Aether's own panels and alerts
        // (palette, settings, confirmations) keep the dropdown open.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible, window.alphaValue > 0.05,
                  !window.isKeyWindow, window.attachedSheet == nil else { return }
            if let key = NSApp.keyWindow, !(key.windowController is DeskController) { return }
            self.dismissDropdown(restoreFocus: false)
        }
    }

    private func stopWatchingWindowDrag() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
        dragWatch?.invalidate()
        dragWatch = nil
    }

    private func finishWindowDrag() {
        stopWatchingWindowDrag()
        guard let window, !snapping, !isDropdown, restorableFrame != nil else {
            rememberFrame()
            return
        }
        let settings = AppModel.shared.settings
        let option = NSEvent.modifierFlags.contains(.option)
        if settings.snapWindows, !option {
            let others = AppModel.shared.controllers.compactMap { id, controller -> CGRect? in
                guard controller !== self, AppModel.shared.desks[id]?.dropdown != true, let other = controller.window,
                      other.isVisible, !other.isMiniaturized, other.isOnActiveSpace, other.alphaValue > 0.5 else { return nil }
                return other.frame
            }
            let screens = NSScreen.screens.map(\.visibleFrame)
            let snapped = Layout.snapFrame(window.frame, others: others, screens: screens, threshold: 12)
            if !nearlyEqual(snapped, window.frame) {
                snapping = true
                window.setFrame(snapped, display: true, animate: false)
                snapping = false
            }
        }
        rememberFrame()
    }

    private func rememberFrame() {
        guard let frame = restorableFrame else { return }
        AppModel.shared.noteFrame(deskID, frame)
    }

    private func showGridSize() {
        guard let desk = AppModel.shared.desks[deskID], let pane = AppModel.shared.panes[desk.focusedID] else { return }
        let terminal: Terminal = pane.chrome.terminal.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return }
        canvas.flash("\(terminal.cols) × \(terminal.rows)", linger: 0.7)
    }

    /// Waits for the next drag event. Returns nil once the button is up even if the
    /// mouse-up never arrived, and `.keyDown` for Escape so callers can cancel.
    private func nextDragEvent(timeout: TimeInterval) -> (event: NSEvent?, ended: Bool) {
        let event = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
            until: Date(timeIntervalSinceNow: timeout),
            inMode: .eventTracking,
            dequeue: true
        )
        if event == nil, NSEvent.pressedMouseButtons & 0x1 == 0 {
            return (nil, true)
        }
        return (event, false)
    }

    func trackDivider(_ grip: DividerGrip, _ start: NSEvent) {
        let origin = start.locationInWindow
        guard let ratio = AppModel.shared.ratio(deskID: deskID, splitID: grip.splitID) else { return }
        let span = max(grip.span, 1)
        let bounds = Layout.dragBounds(span: span, current: ratio)
        let frameInterval = 1.0 / Double(max(window?.screen?.maximumFramesPerSecond ?? 60, 30))
        var pending: Double?
        func apply(_ value: Double) {
            AppModel.shared.setRatio(deskID: deskID, splitID: grip.splitID, ratio: value, bounds: bounds)
            lastDividerSync = CACurrentMediaTime()
            pending = nil
        }
        while true {
            let (event, ended) = nextDragEvent(timeout: pending == nil ? 0.25 : frameInterval)
            if ended { break }
            guard let event else {
                if let value = pending, CACurrentMediaTime() - lastDividerSync >= frameInterval { apply(value) }
                continue
            }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    apply(ratio)
                    return
                }
                continue
            }
            let now = event.locationInWindow
            let delta: CGFloat = grip.axis == .row ? (now.x - origin.x) : (origin.y - now.y)
            pending = ratio + Double(delta / span)
            if event.type == .leftMouseUp { break }
            if let value = pending, CACurrentMediaTime() - lastDividerSync >= frameInterval { apply(value) }
        }
        if let value = pending { apply(value) }
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
            let (event, ended) = nextDragEvent(timeout: 0.25)
            if ended { break }
            guard let event else { continue }
            if event.type == .keyDown {
                if event.keyCode == 53 { return }
                continue
            }
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
    private let veil = ResizeVeil()
    private let hud = LayoutHUD()
    private var hudToken = 0
    private var layoutGeneration = 0
    private var dimToken = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func contentArea() -> CGRect {
        let fallback = bounds.insetBy(dx: 8, dy: 8)
        guard let window, bounds.height > 120 else { return fallback }
        let layout = convert(window.contentLayoutRect, from: nil)
        // Before the window is on screen this rect is empty. Using it pins the pane
        // to a 40pt strip at the bottom, and the shell starts with no rows.
        guard layout.height > 80, bounds.intersects(layout) else { return fallback }
        let top = max(8, bounds.maxY - layout.maxY + 4)
        let height = bounds.height - top - 8
        guard height > 80 else { return fallback }
        return CGRect(x: 8, y: 8, width: max(40, bounds.width - 16), height: height)
    }

    func layOut(desk: Desk, settings: Settings, animated: Bool) {
        layoutGeneration += 1
        let generation = layoutGeneration
        let area = contentArea()
        let placed: (panes: [PlacedPane], dividers: [PlacedDivider])
        let onlyFocused = desk.kind == .stack && desk.maximizedID == nil
        if let maximized = desk.maximizedID, desk.layout.panes.contains(maximized) {
            let inset = Layout.inset(area, by: CGFloat(settings.gap) / 2)
            placed = ([PlacedPane(id: maximized, frame: inset)], [])
        } else if onlyFocused {
            let inset = Layout.inset(area, by: CGFloat(settings.gap) / 2)
            placed = ([PlacedPane(id: desk.focusedID, frame: inset)], [])
        } else {
            placed = Layout.place(desk.layout, in: area, gap: CGFloat(settings.gap))
        }

        let live = Set(desk.layout.panes)
        var departing: [PaneChrome] = []
        for subview in subviews {
            guard let chrome = subview as? PaneChrome, !live.contains(chrome.paneID) else { continue }
            departing.append(chrome)
        }

        var motions: [(PaneChrome, CGRect, CGFloat)] = []
        var visible = Set<String>()
        for item in placed.panes {
            guard let pane = AppModel.shared.panes[item.id] else { continue }
            let chrome = pane.chrome
            let fresh = chrome.superview !== self
            if fresh {
                chrome.alphaValue = 0
                chrome.frame = Self.scaled(item.frame, by: 0.9)
                addSubview(chrome)
            }
            let revealing = chrome.isHidden || chrome.alphaValue < 0.05
            chrome.isHidden = false
            pane.refreshCaption(tone: settings.text)
            pane.chrome.setFocused(item.id == desk.focusedID && window?.isKeyWindow != false, settings: settings)
            wire(pane)
            visible.insert(item.id)
            if animated && (fresh || revealing || !Self.nearly(chrome.frame, item.frame)) {
                if revealing && !fresh {
                    chrome.alphaValue = 0
                    chrome.frame = item.frame
                }
                motions.append((chrome, item.frame, 1))
            } else {
                chrome.frame = item.frame
                chrome.alphaValue = 1
            }
        }
        for id in desk.layout.panes where !visible.contains(id) {
            guard let chrome = AppModel.shared.panes[id]?.chrome else { continue }
            if animated && !chrome.isHidden {
                motions.append((chrome, chrome.frame, 0))
            } else {
                chrome.isHidden = true
                chrome.alphaValue = 1
            }
        }

        let oldDividers = dividers
        dividers = placed.dividers.map { item in
            let grip = DividerGrip(frame: animated ? item.frame : item.frame)
            grip.alphaValue = animated ? 0 : 1
            grip.wantsLayer = true
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

        if animated {
            Motion.group(Motion.snap, {
                for (chrome, frame, alpha) in motions {
                    chrome.animator().frame = frame
                    chrome.animator().alphaValue = alpha
                }
                for chrome in departing {
                    chrome.animator().alphaValue = 0
                    chrome.animator().frame = Self.scaled(chrome.frame, by: 0.92)
                }
                for grip in oldDividers {
                    grip.animator().alphaValue = 0
                }
                for grip in self.dividers {
                    grip.animator().alphaValue = 1
                }
            }, done: { [weak self] in
                for grip in oldDividers {
                    grip.removeFromSuperview()
                }
                guard let self, self.layoutGeneration == generation else { return }
                for chrome in departing {
                    chrome.removeFromSuperview()
                }
                for id in desk.layout.panes where !visible.contains(id) {
                    guard let chrome = AppModel.shared.panes[id]?.chrome else { continue }
                    chrome.isHidden = true
                    chrome.alphaValue = 1
                }
            })
        } else {
            for chrome in departing {
                chrome.removeFromSuperview()
            }
            oldDividers.forEach { $0.removeFromSuperview() }
        }
        if veil.superview === self { addSubview(veil) }
        if hud.superview === self { addSubview(hud) }
        for case let update as UpdateVeil in subviews {
            addSubview(update)
        }
    }

    func beginResizeDim(settings: Settings) {
        dimToken += 1
        let shade = min(0.8, settings.shade + 0.36)
        for pane in AppModel.shared.panes.values where pane.chrome.window === window {
            pane.applyShade(shade, settings: settings)
        }
        veil.alphaValue = 0
        veil.frame = bounds
        addSubview(veil)
        Motion.group(Motion.frostIn) {
            self.veil.animator().alphaValue = 1
        }
    }

    func endResizeDim(_ done: @escaping () -> Void) {
        let token = dimToken
        Motion.group(Motion.frostOut, {
            self.veil.animator().alphaValue = 0
        }, done: { [weak self] in
            guard let self, self.dimToken == token else { return }
            self.veil.removeFromSuperview()
            done()
        })
    }

    func flash(_ title: String, linger: TimeInterval = 0.85) {
        hudToken += 1
        let token = hudToken
        hud.setTitle(title)
        let width = min(bounds.width - 24, max(88, hud.fittingWidth))
        hud.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 58, width: width, height: 32)
        // Repeated flashes (live resize) update in place instead of blinking.
        if hud.superview !== self || hud.alphaValue < 0.05 {
            hud.alphaValue = 0
            addSubview(hud)
        }
        Motion.group(Motion.close) {
            self.hud.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            guard let self, self.hudToken == token else { return }
            Motion.group(Motion.close, {
                self.hud.animator().alphaValue = 0
            }, done: {
                guard self.hudToken == token else { return }
                self.hud.removeFromSuperview()
            })
        }
    }

    private static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let dx = rect.width * (1 - factor) / 2
        let dy = rect.height * (1 - factor) / 2
        return rect.insetBy(dx: dx, dy: dy)
    }

    private static func nearly(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    func frameOfPane(_ id: String) -> CGRect? {
        guard let chrome = AppModel.shared.panes[id]?.chrome, chrome.superview === self, !chrome.isHidden else { return nil }
        return chrome.frame
    }

    func refreshFocus() {
        guard let deskID = (window?.windowController as? DeskController)?.deskID,
              let desk = AppModel.shared.desks[deskID] else { return }
        let key = window?.isKeyWindow == true
        let settings = AppModel.shared.settings
        for id in desk.layout.panes {
            AppModel.shared.panes[id]?.chrome.setFocused(key && id == desk.focusedID, settings: settings)
        }
    }

    private func wire(_ pane: PaneController) {
        let id = pane.id
        pane.onFocus = {
            AppModel.shared.focus(pane: id)
        }
        pane.chrome.onSelect = {
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
        // Swift already owns this window. The default released-when-closed
        // flag sends a second release, which faults in the next pool drain.
        isReleasedWhenClosed = false
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
        GlassPanel.mount(glass, on: self, radius: 12)
    }

    func place(at screenPoint: NSPoint) {
        setFrameOrigin(NSPoint(x: screenPoint.x + 12, y: screenPoint.y - 28))
    }
}

final class ResizeVeil: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LayoutHUD: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        label.stringValue = title
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        ceil(label.intrinsicContentSize.width) + 36
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 6)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSGlassEffectView {
    /// Interactive glass arrived in macOS 27. Setting it by key keeps this
    /// source building against the macOS 26 SDK used to publish updates.
    func enableInteractiveGlass() {
        let setter = NSSelectorFromString("setEffectIsInteractive:")
        guard responds(to: setter) else { return }
        setValue(true, forKey: "effectIsInteractive")
    }
}
