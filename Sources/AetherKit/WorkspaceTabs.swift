import AppKit

/// The titlebar, right of the traffic lights: where you are, the workspace tabs in a
/// track, then the launcher and +. The selected tab sits on a pill that slides between tabs.
@MainActor
final class WorkspaceTabStrip: NSView {
    var deskID = ""
    private let place = WorkspacePlace()
    private let track = NSView()
    private let pill = NSView()
    private var chips: [WorkspaceTabChip] = []
    private var separators: [NSView] = []
    private let launch = TitlebarButton(symbol: "command", label: "Launch a command")
    private let plus = TitlebarButton(symbol: "plus", label: "New tab")
    private var tone: TextTone = .light
    private var selectedID = ""
    private var drag: (chip: WorkspaceTabChip, grab: CGFloat, moved: Bool)?
    private var laidOut = false
    /// How far the tabs are scrolled when there are more than fit.
    private var scrollX: CGFloat = 0
    private var scrollToSelection = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width]
        track.wantsLayer = true
        track.layer?.masksToBounds = true
        pill.wantsLayer = true
        addSubview(place)
        addSubview(track)
        track.addSubview(pill)
        launch.target = self
        launch.action = #selector(openLauncher)
        plus.target = self
        plus.action = #selector(addTab)
        addSubview(launch)
        addSubview(plus)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Workspace tabs")
        applyTone()
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
        let leading = (buttons.max() ?? 70) + 14
        let next = NSRect(x: leading, y: 0, width: max(48, titlebar.bounds.width - leading - 8), height: titlebar.bounds.height)
        if frame != next { frame = next }
    }

    func reload(_ desk: Desk, tone: TextTone) {
        if tone != self.tone {
            self.tone = tone
            applyTone()
        }
        launch.toolTip = Self.tip("Launch a command", .launch)
        plus.toolTip = Self.tip("New tab", .newTab)
        let items = desk.tabs.map { tab in
            WorkspaceTabChip.Item(
                id: tab.id,
                label: Self.label(for: tab, in: desk),
                selected: tab.id == desk.activeTabID,
                icons: Self.icons(for: tab),
                closable: desk.tabs.count > 1,
                status: tab.id == desk.activeTabID ? .none : Self.status(for: tab)
            )
        }
        let focused = AppModel.shared.panes[desk.focusedID]
        place.set(folder: focused.map { Self.folderName($0.cwd) } ?? "", host: System.hostName)

        // Mid-drag the strip owns the order; take the new labels and leave the rest for the drop.
        if drag != nil {
            for chip in chips {
                if let item = items.first(where: { $0.id == chip.item.id }) { chip.item = item }
            }
            return
        }
        var fresh: [WorkspaceTabChip] = []
        let byID = Dictionary(chips.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [WorkspaceTabChip] = []
        for item in items {
            if let chip = byID[item.id] {
                next.append(chip)
            } else {
                let chip = makeChip()
                fresh.append(chip)
                next.append(chip)
            }
        }
        let gone = chips.filter { chip in !items.contains { $0.id == chip.item.id } }
        chips = next
        for (chip, item) in zip(chips, items) {
            chip.tone = tone
            chip.item = item
        }
        let selection = items.first(where: \.selected)?.id ?? ""
        let changed = !fresh.isEmpty || !gone.isEmpty || selection != selectedID
        if changed { scrollToSelection = true }
        selectedID = selection
        for chip in gone { dismiss(chip) }
        layoutStrip(animated: laidOut && changed, fresh: fresh)
        laidOut = true
    }

    private func makeChip() -> WorkspaceTabChip {
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
        chip.onCloseOthers = { [weak self] id in
            guard let self else { return }
            AppModel.shared.closeOtherTabs(keeping: id, in: self.deskID)
        }
        chip.onHover = { [weak self] in self?.refreshSeparators() }
        chip.onDrag = { [weak self] chip, event, phase in self?.track(chip, event, phase) }
        track.addSubview(chip)
        return chip
    }

    private func dismiss(_ chip: WorkspaceTabChip) {
        chip.onHover = nil
        Motion.group(Motion.close, {
            chip.animator().alphaValue = 0
            if !Motion.reduced {
                chip.animator().frame = NSRect(x: chip.frame.minX, y: chip.frame.minY, width: max(0, chip.frame.width * 0.6), height: chip.frame.height)
            }
        }, done: {
            chip.removeFromSuperview()
        })
    }

    override func layout() {
        super.layout()
        if drag == nil { layoutStrip(animated: false, fresh: []) }
    }

    /// A wheel or trackpad swipe over the tabs scrolls them when there are more than fit.
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard drag == nil, delta != 0 else { return super.scrollWheel(with: event) }
        scrollX -= event.hasPreciseScrollingDeltas ? delta : delta * 12
        layoutStrip(animated: false, fresh: [])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Empty titlebar still drags the window and double-click still zooms it.
        if hit === self || hit === track || hit === pill { return nil }
        return hit
    }

    // MARK: Layout

    nonisolated static let inset: CGFloat = 3
    nonisolated static let gap: CGFloat = 2

    private func layoutStrip(animated: Bool, fresh: [WorkspaceTabChip]) {
        let height = bounds.height
        let button: CGFloat = 26
        let chipHeight = min(28, max(20, height - 14))
        let trackHeight = chipHeight + Self.inset * 2
        let midY = (height - trackHeight) / 2

        plus.frame = NSRect(x: bounds.width - button, y: (height - button) / 2, width: button, height: button)
        launch.frame = NSRect(x: plus.frame.minX - button - 2, y: plus.frame.minY, width: button, height: button)

        let showPlace = bounds.width > 560 && !place.isEmpty
        place.isHidden = !showPlace
        var x: CGFloat = 0
        if showPlace {
            let width = min(170, place.preferredWidth)
            place.frame = NSRect(x: 0, y: 0, width: width, height: height)
            x = width + 14
        }

        let available = max(0, launch.frame.minX - 10 - x)
        let widths = Self.fit(chips.map { $0.preferredWidth(height: chipHeight) }, into: available - Self.inset * 2,
                              keep: chips.firstIndex { $0.item.selected })
        var cursor = Self.inset
        var frames: [NSRect] = []
        for width in widths {
            frames.append(NSRect(x: cursor, y: Self.inset, width: width, height: chipHeight))
            cursor += width + Self.gap
        }
        let contentWidth = chips.isEmpty ? 0 : cursor - Self.gap + Self.inset
        let trackWidth = min(contentWidth, available)
        let overflow = max(0, contentWidth - trackWidth)
        if let selected = chips.firstIndex(where: { $0.item.selected }), scrollToSelection, overflow > 0 {
            let frame = frames[selected]
            if frame.minX - scrollX < Self.inset { scrollX = frame.minX - Self.inset }
            if frame.maxX - scrollX > trackWidth - Self.inset { scrollX = frame.maxX - trackWidth + Self.inset }
        }
        scrollToSelection = false
        scrollX = min(max(0, scrollX), overflow)
        frames = frames.map { $0.offsetBy(dx: -scrollX, dy: 0) }
        track.frame = NSRect(x: x, y: midY, width: trackWidth, height: trackHeight)
        track.layer?.cornerRadius = trackHeight / 2 - 1

        let selected = chips.firstIndex { $0.item.selected }
        let pillFrame = selected.map { frames[$0] } ?? .zero
        let apply = {
            for (index, chip) in self.chips.enumerated() where chip !== self.drag?.chip {
                let target = frames[index]
                if fresh.contains(where: { $0 === chip }) { continue }
                if animated { chip.animator().frame = target } else { chip.frame = target }
            }
            if animated, self.pill.alphaValue > 0, selected != nil {
                self.pill.animator().frame = pillFrame
            } else {
                self.pill.frame = pillFrame
            }
            self.pill.alphaValue = selected == nil ? 0 : 1
        }
        for chip in fresh {
            guard let index = chips.firstIndex(where: { $0 === chip }) else { continue }
            let target = frames[index]
            chip.frame = animated && !Motion.reduced ? NSRect(x: target.minX, y: target.minY, width: target.width * 0.7, height: target.height) : target
            chip.alphaValue = animated ? 0 : 1
        }
        if animated {
            Motion.group(Motion.snap, {
                apply()
                for chip in fresh {
                    guard let index = self.chips.firstIndex(where: { $0 === chip }) else { continue }
                    chip.animator().frame = frames[index]
                    chip.animator().alphaValue = 1
                }
            })
        } else {
            apply()
        }
        pill.layer?.cornerRadius = chipHeight / 2 - 1
        refreshSeparators(frames: frames)
    }

    /// Each tab gets the width it asks for, up to 220. When they do not fit, they share the room
    /// evenly, but never go below an icon's width.
    /// The tab at `keep` (the selected one) stays readable, up to 150, while the rest squeeze.
    nonisolated static func fit(_ wanted: [CGFloat], into room: CGFloat, keep: Int? = nil, gap: CGFloat = gap) -> [CGFloat] {
        guard !wanted.isEmpty else { return [] }
        let capped = wanted.map { min(220, max(96, $0)) }
        let gaps = gap * CGFloat(wanted.count - 1)
        if capped.reduce(0, +) + gaps <= room { return capped }
        let even = max(36, floor((room - gaps) / CGFloat(wanted.count)))
        var widths = capped.map { min($0, even) }
        if let keep, widths.indices.contains(keep), wanted.count > 1 {
            let kept = min(capped[keep], max(even, 150))
            let rest = max(36, floor((room - gaps - kept) / CGFloat(wanted.count - 1)))
            widths = capped.indices.map { $0 == keep ? kept : min(capped[$0], rest) }
        }
        return widths
    }

    private func refreshSeparators(frames: [NSRect]? = nil) {
        let frames = frames ?? chips.map(\.frame)
        let needed = max(0, chips.count - 1)
        while separators.count < needed {
            let line = NSView()
            line.wantsLayer = true
            track.addSubview(line, positioned: .above, relativeTo: pill)
            separators.append(line)
        }
        while separators.count > needed {
            separators.removeLast().removeFromSuperview()
        }
        let ink = tone.ink
        for (index, line) in separators.enumerated() where index + 1 < frames.count {
            let left = chips[index], right = chips[index + 1]
            let x = (frames[index].maxX + frames[index + 1].minX) / 2
            let height = frames[index].height * 0.46
            line.frame = NSRect(x: round(x) - 0.5, y: frames[index].midY - height / 2, width: 1, height: height)
            line.layer?.backgroundColor = ink.withAlphaComponent(0.16).cgColor
            let hidden = left.item.selected || right.item.selected || left.hovering || right.hovering || drag != nil
            line.animator().alphaValue = hidden ? 0 : 1
        }
    }

    private func applyTone() {
        let ink = tone.ink
        track.layer?.backgroundColor = ink.withAlphaComponent(tone == .light ? 0.055 : 0.045).cgColor
        track.layer?.borderColor = ink.withAlphaComponent(0.06).cgColor
        track.layer?.borderWidth = 0.5
        pill.layer?.backgroundColor = (tone == .light ? NSColor.white.withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.72)).cgColor
        pill.layer?.borderColor = (tone == .light ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.08)).cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = tone == .light ? 0.28 : 0.12
        pill.layer?.shadowRadius = 3
        pill.layer?.shadowOffset = CGSize(width: 0, height: -1)
        place.tone = tone
        launch.tone = tone
        plus.tone = tone
        for chip in chips { chip.tone = tone }
        refreshSeparators()
    }

    // MARK: Dragging to reorder

    private func track(_ chip: WorkspaceTabChip, _ event: NSEvent, _ phase: WorkspaceTabChip.DragPhase) {
        let x = track.convert(event.locationInWindow, from: nil).x
        switch phase {
        case .began:
            drag = (chip, x - chip.frame.minX, false)
        case .moved:
            guard var current = drag, current.chip === chip else { return }
            if !current.moved {
                guard abs(x - current.grab - chip.frame.minX) > 4 else { return }
                current.moved = true
                track.addSubview(chip, positioned: .above, relativeTo: nil)
                refreshSeparators()
            }
            drag = current
            let maxX = track.bounds.width - Self.inset - chip.frame.width
            chip.frame.origin.x = min(max(Self.inset, x - current.grab), maxX)
            if chip.item.selected { pill.frame.origin.x = chip.frame.minX }
            let index = chips.firstIndex { $0 === chip } ?? 0
            let target = chips.filter { $0 !== chip }.filter { $0.frame.midX < chip.frame.midX }.count
            if target != index {
                chips.remove(at: index)
                chips.insert(chip, at: target)
                layoutStrip(animated: true, fresh: [])
            }
        case .ended:
            guard let current = drag, current.chip === chip else { return }
            drag = nil
            if current.moved {
                let index = chips.firstIndex { $0 === chip } ?? 0
                AppModel.shared.moveTab(chip.item.id, to: index, in: deskID)
                layoutStrip(animated: true, fresh: [])
            } else {
                chip.onSelect?(chip.item.id)
            }
        }
    }

    // MARK: Actions

    private static func tip(_ text: String, _ action: AppAction) -> String {
        let chord = AppModel.shared.settings.keys.chord(action)
        return chord.key.isEmpty ? text : "\(text)  \(chord.symbol)"
    }

    @objc private func addTab() {
        AppModel.shared.newTab(in: deskID)
    }

    @objc private func openLauncher() {
        let item = NSMenuItem()
        item.representedObject = AppAction.launch.rawValue
        NSApp.sendAction(Selector(("runAction:")), to: nil, from: item)
    }

    static func rename(tab id: String, in deskID: String) {
        guard let desk = AppModel.shared.desks[deskID],
              let tab = desk.tabs.first(where: { $0.id == id }),
              let window = AppModel.shared.controllers[deskID]?.window,
              window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave it empty to name the tab after what is running in it."
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

    // MARK: What a tab shows

    /// A named tab shows its name. Otherwise what runs in its focused terminal, then where:
    /// "npm run dev  ~/site", or "zsh  ~/site" at a prompt.
    static func label(for tab: WorkspaceTab, in desk: Desk) -> (title: String, detail: String) {
        let name = tab.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return (name, "") }
        guard let pane = AppModel.shared.panes[tab.focusedID] else { return (tab.title(from: desk.panes), "") }
        if let custom = pane.customTitle, !custom.isEmpty { return (custom, "") }
        let path = System.displayPath(pane.cwd)
        if pane.runningCommand() != nil {
            return (pane.title, path)
        }
        return (pane.tabProcess().name, path)
    }

    /// What a tab in the background is up to: a red or green dot for a command that finished
    /// while you were away, or a pulse while something still runs.
    static func status(for tab: WorkspaceTab) -> WorkspaceTabChip.Status {
        let unseen = AppModel.shared.unseenFinishes[tab.id]
        if let unseen, unseen != 0 { return .failed }
        let busy = Layout.visualIDs(tab.layout).contains { AppModel.shared.panes[$0]?.runningCommand() != nil }
        if busy { return .busy }
        return unseen == nil ? .none : .succeeded
    }

    static func folderName(_ path: String) -> String {
        let shown = System.displayPath(path)
        if shown == "~" || shown == "/" { return shown }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func icons(for tab: WorkspaceTab) -> [ProcessIcon.Key] {
        var keys: [ProcessIcon.Key] = []
        for id in Layout.visualIDs(tab.layout) {
            guard let pane = AppModel.shared.panes[id] else { continue }
            let process = pane.tabProcess()
            let key = ProcessIcon.Key(name: process.name, path: process.path.flatMap(ProcessIcon.bundle(containing:)))
            guard !keys.contains(key) else { continue }
            keys.append(key)
            if keys.count == 3 { break }
        }
        return keys
    }
}

extension TextTone {
    /// The color drawn on the glass: white for light text, near-black for dark.
    var ink: NSColor {
        self == .dark ? NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1) : .white
    }
}

/// The folder you are in and the Mac you are on, left of the tabs.
@MainActor
private final class WorkspacePlace: NSView {
    private var folder = ""
    private var host = ""
    var tone: TextTone = .light { didSet { needsDisplay = true } }

    var isEmpty: Bool { folder.isEmpty }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(folder: String, host: String) {
        guard folder != self.folder || host != self.host else { return }
        self.folder = folder
        self.host = host
        setAccessibilityLabel("\(folder) on \(host)")
        needsDisplay = true
    }

    private var titleFont: NSFont { .systemFont(ofSize: 12.5, weight: .semibold) }
    private var hostFont: NSFont { .systemFont(ofSize: 10.5, weight: .regular) }

    var preferredWidth: CGFloat {
        let title = (folder as NSString).size(withAttributes: [.font: titleFont]).width
        let sub = (host as NSString).size(withAttributes: [.font: hostFont]).width
        return ceil(26 + max(title, sub))
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = tone.ink
        if let symbol = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            let tinted = symbol.tinted(ink.withAlphaComponent(0.62))
            let size = tinted.size
            tinted.draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let x: CGFloat = 26
        let width = bounds.width - x
        let top = bounds.midY - 15
        (folder as NSString).draw(in: NSRect(x: x, y: top, width: width, height: 16), withAttributes: [
            .font: titleFont, .foregroundColor: ink.withAlphaComponent(0.92), .paragraphStyle: style,
        ])
        (host as NSString).draw(in: NSRect(x: x, y: top + 16, width: width, height: 14), withAttributes: [
            .font: hostFont, .foregroundColor: ink.withAlphaComponent(0.5), .paragraphStyle: style,
        ])
    }
}

@MainActor
final class WorkspaceTabChip: NSView {
    struct Item: Equatable {
        var id: String
        var label: (title: String, detail: String)
        var selected: Bool
        var icons: [ProcessIcon.Key]
        var closable: Bool
        var status: Status = .none

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.label == b.label && a.selected == b.selected && a.icons == b.icons
                && a.closable == b.closable && a.status == b.status
        }
    }

    enum Status: Equatable { case none, busy, succeeded, failed }
    private let badge = CALayer()

    enum DragPhase { case began, moved, ended }

    var item = Item(id: "", label: ("", ""), selected: false, icons: [], closable: false) {
        didSet {
            guard item != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(item.label.title)
            setAccessibilityValue(item.label.detail)
            setAccessibilitySelected(item.selected)
            if item.status != oldValue.status { refreshBadge() }
        }
    }
    var tone: TextTone = .light {
        didSet { if tone != oldValue { needsDisplay = true; refreshBadge() } }
    }
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    var onCloseOthers: ((String) -> Void)?
    var onHover: (() -> Void)?
    var onDrag: ((WorkspaceTabChip, NSEvent, DragPhase) -> Void)?
    private(set) var hovering = false
    private var overClose = false
    private var pressedClose = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        badge.cornerRadius = 4.5
        badge.borderWidth = 1.5
        badge.isHidden = true
        layer?.addSublayer(badge)
    }

    override func layout() {
        super.layout()
        let size = iconSize(height: bounds.height)
        // The top-right corner of the front icon.
        badge.frame = CGRect(x: 8 + size - 6, y: (bounds.height - size) / 2 - 3, width: 9, height: 9)
    }

    private func refreshBadge() {
        badge.removeAllAnimations()
        badge.isHidden = item.status == .none
        badge.borderColor = NSColor(white: tone == .light ? 0.18 : 0.92, alpha: 1).cgColor
        switch item.status {
        case .none:
            setAccessibilityHelp(nil)
        case .busy:
            badge.backgroundColor = NSColor.controlAccentColor.cgColor
            setAccessibilityHelp("Running")
            guard !Motion.reduced else { break }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            badge.add(pulse, forKey: "pulse")
        case .succeeded:
            badge.backgroundColor = NSColor.systemGreen.cgColor
            setAccessibilityHelp("Finished")
        case .failed:
            badge.backgroundColor = NSColor.systemRed.cgColor
            setAccessibilityHelp("Failed")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var titleFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }
    private var detailFont: NSFont { .systemFont(ofSize: 12, weight: .regular) }

    func preferredWidth(height: CGFloat) -> CGFloat {
        let title = (item.label.title as NSString).size(withAttributes: [.font: titleFont]).width
        let detail = item.label.detail.isEmpty ? 0 : 6 + (item.label.detail as NSString).size(withAttributes: [.font: detailFont]).width
        return ceil(10 + iconsWidth(height: height) + 7 + title + detail + 26)
    }

    private func iconSize(height: CGFloat) -> CGFloat { floor(height - 10) }

    private func iconsWidth(height: CGFloat) -> CGFloat {
        let size = iconSize(height: height)
        guard !item.icons.isEmpty else { return size }
        return size + CGFloat(item.icons.count - 1) * size * 0.55
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.width - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    private var showsClose: Bool { item.closable && (hovering || item.selected) }

    override func draw(_ dirtyRect: NSRect) {
        let ink = tone.ink
        let selected = item.selected
        if hovering, !selected {
            ink.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2 - 1, yRadius: bounds.height / 2 - 1).fill()
        }

        let size = iconSize(height: bounds.height)
        var x: CGFloat = 8
        let iconY = (bounds.height - size) / 2
        let keys = item.icons.isEmpty ? [ProcessIcon.Key(name: "zsh", path: nil)] : item.icons
        // Drawn back to front so the first icon sits on top, like a fanned stack.
        let rects = keys.indices.map { NSRect(x: x + CGFloat($0) * size * 0.55, y: iconY, width: size, height: size) }
        for (key, rect) in zip(keys, rects).reversed() {
            ProcessIcon.draw(key, in: rect, dimmed: !selected && !hovering)
        }
        x += iconsWidth(height: bounds.height) + 7

        let closeRoom: CGFloat = showsClose ? 24 : 10
        let room = max(0, bounds.width - x - closeRoom)
        let alpha: CGFloat = selected ? 0.95 : (hovering ? 0.8 : 0.6)
        let line = NSMutableAttributedString(string: item.label.title, attributes: [
            .font: titleFont, .foregroundColor: ink.withAlphaComponent(alpha),
        ])
        if !item.label.detail.isEmpty {
            line.append(NSAttributedString(string: "  " + item.label.detail, attributes: [
                .font: detailFont, .foregroundColor: ink.withAlphaComponent(alpha * 0.55),
            ]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        if room > 8 {
            // One line, truncated: a box shorter than the line fragment would draw nothing at all.
            let textHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading) + 2
            line.draw(in: NSRect(x: x, y: (bounds.height - textHeight) / 2, width: room, height: textHeight))
        }

        if showsClose, bounds.width > 64 {
            let rect = closeRect
            if overClose {
                ink.withAlphaComponent(pressedClose ? 0.22 : 0.13).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            let glyph = rect.insetBy(dx: 5, dy: 5)
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: glyph.minX, y: glyph.minY))
            cross.line(to: NSPoint(x: glyph.maxX, y: glyph.maxY))
            cross.move(to: NSPoint(x: glyph.maxX, y: glyph.minY))
            cross.line(to: NSPoint(x: glyph.minX, y: glyph.maxY))
            cross.lineWidth = 1.3
            cross.lineCapStyle = .round
            ink.withAlphaComponent(overClose ? 0.9 : 0.55).setStroke()
            cross.stroke()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        overClose = false
        needsDisplay = true
        onHover?()
    }

    override func mouseMoved(with event: NSEvent) {
        let inside = showsClose && closeRect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil))
        if inside != overClose {
            overClose = inside
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A second click renames. Third and later clicks of the same burst do nothing,
        // so they never start a drag that the matching mouse-up would not end.
        if event.clickCount >= 2 {
            if event.clickCount == 2 { onRename?(item.id) }
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if showsClose, closeRect.insetBy(dx: -3, dy: -3).contains(local) {
            pressedClose = true
            needsDisplay = true
            return
        }
        onDrag?(self, event, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !pressedClose else { return }
        onDrag?(self, event, .moved)
    }

    override func mouseUp(with event: NSEvent) {
        if pressedClose {
            pressedClose = false
            needsDisplay = true
            if closeRect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil)) {
                onClose?(item.id)
            }
            return
        }
        guard event.clickCount < 2 else { return }
        onDrag?(self, event, .ended)
    }

    /// Middle-click closes, as in a browser.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, item.closable,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClose?(item.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab…", action: #selector(rename), keyEquivalent: "")
        if item.closable {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
            menu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOthers), keyEquivalent: "")
        }
        for entry in menu.items { entry.target = self }
        return menu
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(item.id)
        return true
    }

    @objc private func rename() { onRename?(item.id) }
    @objc private func closeTab() { onClose?(item.id) }
    @objc private func closeOthers() { onCloseOthers?(item.id) }
}

/// A round, borderless titlebar button that lights up under the pointer.
@MainActor
private final class TitlebarButton: NSButton {
    var tone: TextTone = .light { didSet { refresh() } }
    private var hovering = false

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setAccessibilityLabel(label)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    private func refresh() {
        let ink = tone.ink
        contentTintColor = ink.withAlphaComponent(hovering ? 0.9 : 0.58)
        layer?.backgroundColor = ink.withAlphaComponent(hovering ? 0.1 : 0).cgColor
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

enum ProcessIcon {
    struct Key: Hashable {
        var name: String
        /// The .app the process runs from, when it runs from one.
        var path: String?
    }

    /// Looking up an app's icon reads the disk. The strip refreshes every second, so remember them.
    @MainActor private static var cache: [Key: NSImage?] = [:]

    @MainActor static func appIcon(_ key: Key) -> NSImage? {
        if let hit = cache[key] { return hit }
        let image = lookup(key)
        cache[key] = image
        return image
    }

    @MainActor private static func lookup(_ key: Key) -> NSImage? {
        if let app = key.path {
            return NSWorkspace.shared.icon(forFile: app)
        }
        let token = key.name.lowercased()
        if shells.contains(token) { return nil }
        if let identifier = bundleID(token),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let applications = "/Applications/\(key.name).app"
        if FileManager.default.fileExists(atPath: applications) {
            return NSWorkspace.shared.icon(forFile: applications)
        }
        return nil
    }

    /// An app's own icon, or a dark tile with a terminal glyph for shells and plain commands.
    @MainActor static func draw(_ key: Key, in rect: NSRect, dimmed: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        if let image = appIcon(key) {
            image.draw(in: rect.insetBy(dx: -1, dy: -1), from: .zero, operation: .sourceOver, fraction: dimmed ? 0.85 : 1)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let style = TileStyle.of(key.name)
        let radius = rect.width * 0.3
        let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGradient(starting: style.top, ending: style.bottom)?.draw(in: tile, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        // Light catches the top edge only, as on the app icon.
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        rim.lineWidth = 0.75
        NSColor.white.withAlphaComponent(0.28).setStroke()
        NSGraphicsContext.current?.cgContext.clip(to: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let ink = NSColor.white.withAlphaComponent(dimmed ? 0.78 : 0.97)
        if let symbol = style.symbol {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: key.name)?
                .withSymbolConfiguration(.init(pointSize: rect.width * 0.46, weight: .bold)) {
                let tinted = image.tinted(ink)
                let size = tinted.size
                tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
        } else {
            drawPrompt(in: rect, ink: ink, cursor: style.cursor.withAlphaComponent(dimmed ? 0.8 : 1))
        }
    }

    /// The app icon's mark, drawn small: a chevron and a cursor.
    private static func drawPrompt(in rect: NSRect, ink: NSColor, cursor: NSColor) {
        let unit = rect.width
        let left = rect.minX + unit * 0.27, tip = rect.minX + unit * 0.5
        // The rect is flipped in the strip, so "up" is smaller y; the shape is symmetric either way.
        let mid = rect.midY - unit * 0.03
        let reach = unit * 0.2
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: left, y: mid - reach))
        chevron.line(to: NSPoint(x: tip, y: mid))
        chevron.line(to: NSPoint(x: left, y: mid + reach))
        chevron.lineWidth = max(1.6, unit * 0.12)
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        ink.setStroke()
        chevron.stroke()
        let height = max(1.6, unit * 0.11)
        let bar = NSRect(x: tip + unit * 0.06, y: mid + reach - height / 2, width: unit * 0.2, height: height)
        cursor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
    }

    /// One color per kind of program, so a glance at the strip says what each tab is doing.
    private struct TileStyle {
        var top: NSColor
        var bottom: NSColor
        var symbol: String?
        var cursor: NSColor = NSColor(srgbRed: 0.49, green: 0.89, blue: 0.96, alpha: 1)

        static func of(_ name: String) -> TileStyle {
            func rgb(_ hex: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
            switch name.lowercased() {
            case "ssh", "mosh", "et", "telnet", "nc":
                return TileStyle(top: rgb(0x4C8DF6), bottom: rgb(0x1F4FC4), symbol: "network")
            case "vim", "nvim", "vi", "nano", "emacs", "hx", "helix", "micro":
                return TileStyle(top: rgb(0x3FCF7A), bottom: rgb(0x14803F), symbol: "pencil.line")
            case "git", "lazygit", "tig", "gitui", "gh":
                return TileStyle(top: rgb(0xF5843C), bottom: rgb(0xC2410C), symbol: "arrow.triangle.branch")
            case "htop", "btop", "top", "glances", "bottom", "btm":
                return TileStyle(top: rgb(0xB06CF5), bottom: rgb(0x6D28C9), symbol: "waveform.path.ecg")
            case "python", "python3", "ipython", "ruby", "irb", "lua", "ghci":
                return TileStyle(top: rgb(0xEBB82E), bottom: rgb(0xA66A08), symbol: "curlybraces")
            case "man", "less", "more", "bat", "tail":
                return TileStyle(top: rgb(0x7B8798), bottom: rgb(0x3B4556), symbol: "text.alignleft")
            case "make", "cargo", "swift", "go", "gradle", "xcodebuild", "cmake", "ninja":
                return TileStyle(top: rgb(0xE85D75), bottom: rgb(0xA3203D), symbol: "hammer.fill")
            case "ping", "arp", "curl", "wget", "nmap", "traceroute", "dig":
                return TileStyle(top: rgb(0x2EC4C9), bottom: rgb(0x0E7C86), symbol: "dot.radiowaves.left.and.right")
            default:
                if shells.contains(name.lowercased()) {
                    return TileStyle(top: rgb(0x3A4154), bottom: rgb(0x171B26), symbol: nil)
                }
                // Anything else running: the prompt mark on the app's own indigo.
                return TileStyle(top: rgb(0x5B5FE8), bottom: rgb(0x2E2A9E), symbol: nil, cursor: rgb(0xC7D2FE))
            }
        }
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "nu", "pwsh", "-zsh", "-bash"]

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
        case "bun": "com.oven-sh.bun"
        case "fish": "com.ridiculousfish.fishapp"
        case "iterm2", "iterm": "com.googlecode.iterm2"
        case "ghostty": "com.mitchellh.ghostty"
        case "codex": "com.openai.chat"
        default: nil
        }
    }
}
