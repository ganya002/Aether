import AppKit

@MainActor
public enum AetherApplication {
    private static let delegate = AppDelegate()

    public static func launch() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let palette = CommandPalette()
    private let settingsPanel = SettingsController()
    private let shortcuts = ShortcutController()
    private let model = AppModel.shared
    private var boundMenus: [AppAction: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        palette.onPick = { [weak self] row in
            self?.perform(row)
        }
        buildMenus()
        NotificationCenter.default.addObserver(forName: .aetherBindingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyKeyBindings()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let content = event.window?.contentView else { return event }
            // Frame test, not hitTest. A blurred pane is rasterized, and hitTest
            // then lands on the pane that was focused before.
            func pane(in view: NSView) -> PaneChrome? {
                for subview in view.subviews.reversed() {
                    if let found = pane(in: subview) { return found }
                    guard let chrome = subview as? PaneChrome, !chrome.isHidden else { continue }
                    let local = view.convert(event.locationInWindow, from: nil)
                    if chrome.frame.contains(local) { return chrome }
                }
                return nil
            }
            if let chrome = pane(in: content) {
                AppModel.shared.focus(pane: chrome.paneID)
            }
            return event
        }
        if CommandLine.arguments.contains("--smoke") {
            runSmoke()
            return
        }
        AgentDesk.shared.start()
        model.restoreOrCreate()
        HotkeyCenter.onFire = { [weak self] in
            self?.model.toggleDropdown()
        }
        HotkeyCenter.install()
        applyKeyBindings()
        NSApp.activate(ignoringOtherApps: true)
        guard !System.isDev else { return }
        promptToMoveIntoApplications()
        UpdateCenter.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !System.isDev else { return }
        UpdateCenter.shared.checkSoon()
    }

    /// The curl installer leaves Aether in Downloads and launches it. The first time it
    /// starts from anywhere other than an Applications folder, say so.
    private func promptToMoveIntoApplications() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let path = bundle.standardizedFileURL.path
        let homes = [
            "/Applications/",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/",
        ]
        if homes.contains(where: { path.hasPrefix($0) }) { return }
        let key = "aether.promptedApplicationsFolder"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let alert = NSAlert()
            alert.messageText = "Drag Aether into Applications"
            alert.informativeText = "Aether is running from \(bundle.deletingLastPathComponent().lastPathComponent). Drag Aether.app into your Applications folder so Spotlight and the Dock can open it."
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([bundle])
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reopen()
        return false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let auxiliary = NSApp.keyWindow === palette.window || NSApp.keyWindow === settingsPanel.window || NSApp.keyWindow === shortcuts.window
        if auxiliary && menuItem.action == #selector(toggleMaximize) {
            return false
        }
        switch menuItem.action {
        case #selector(toggleBroadcast):
            menuItem.state = model.keyBroadcast ? .on : .off
            return model.keyDeskID != nil
        case #selector(closePane), #selector(splitRight), #selector(splitDown), #selector(toggleMaximize),
             #selector(equalizeSplits), #selector(focusDirectional(_:)), #selector(resizeDirectional(_:)),
             #selector(cycleLayoutForward), #selector(cycleLayoutBackward):
            return model.keyDeskID != nil
        default:
            return true
        }
    }

    private func perform(_ row: PaletteRow) {
        switch row.kind {
        case .command(let command, let newWindow):
            if newWindow { model.newWindow(command: command) } else { model.newPane(command: command) }
        case .tool(let name):
            model.newPane(command: name)
        case .action(let action):
            switch action {
            case .newPane: model.newPane()
            case .newWindow: model.newWindow()
            case .splitRight: model.splitFocused(.right)
            case .splitDown: model.splitFocused(.bottom)
            case .close: closeFocusedPane()
            case .maximize: model.toggleMaximize()
            case .equalize: model.equalize()
            case .columns: model.arrange(.columns)
            case .rows: model.arrange(.rows)
            case .grid: model.arrange(.grid)
            case .nextLayout: model.cycleLayout(by: 1)
            case .arrangeWindows: model.arrangeWindows()
            case .broadcast: model.toggleBroadcast()
            case .settings: settingsPanel.show()
            case .find: showFind()
            case .dropdown: model.toggleDropdown()
            }
        }
    }

    private func closeFocusedPane() {
        guard let deskID = model.keyDeskID, let focused = model.desks[deskID]?.focusedID else { return }
        model.closePane(focused)
    }

    private func showFind() {
        guard let deskID = model.keyDeskID, let focused = model.desks[deskID]?.focusedID, let pane = model.panes[focused] else { return }
        model.controllers[deskID]?.window?.makeKeyAndOrderFront(nil)
        model.controllers[deskID]?.window?.makeFirstResponder(pane.chrome.terminal)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: pane.chrome.terminal, from: item)
    }

    private func runSmoke() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let pattern = NSWindow(
            contentRect: NSRect(x: screen.midX - 360, y: screen.midY - 220, width: 760, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        pattern.title = "Behind Aether"
        pattern.contentView = SmokeStripes(frame: pattern.contentView?.bounds ?? .zero)
        pattern.orderFrontRegardless()

        model.newWindow(command: "printf 'AETHER_READY\\n'")
        model.splitFocused(.right, command: "printf 'AETHER_SPLIT\\n'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let path = "/tmp/aether-smoke.png"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", path]
            try? task.run()
            task.waitUntilExit()
            let pids = self.model.panes.values.map { $0.chrome.terminal.process.shellPid }
            let live = pids.filter { $0 > 0 }
            let glassCount = self.model.controllers.values.filter { $0.window?.contentView === $0.glass }.count
            let report = "panes=\(self.model.panes.count) pids=\(live.count) windows=\(glassCount) shot=\(FileManager.default.fileExists(atPath: path))"
            try? report.write(toFile: "/tmp/aether-smoke.txt", atomically: true, encoding: .utf8)
            let ok = self.model.panes.count >= 2 && live.count >= 2 && glassCount >= 1 && FileManager.default.fileExists(atPath: path)
            self.model.shutdownAll()
            exit(ok ? 0 : 1)
        }
    }

    private func buildMenus() {
        let main = NSMenu()
        main.addItem(menu("Aether", items: [
            item("About Aether", #selector(showAbout), ""),
            bind(.settings, item("Settings…", #selector(showSettings), ",", [.command])),
            .separator(),
            bind(.quit, quitItem()),
        ]))
        main.addItem(menu("File", items: [
            bind(.newWindow, item("New Window", #selector(newWindow), "n")),
            bind(.newPane, item("New Terminal", #selector(newPane), "t")),
            bind(.splitRight, item("Split Right", #selector(splitRight), "d")),
            bind(.splitDown, item("Split Down", #selector(splitDown), "d", [.command, .shift])),
            .separator(),
            bind(.closePane, item("Close Terminal", #selector(closePane), "w")),
            bind(.closeWindow, responderItem("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])),
        ]))
        let find = bind(.find, item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f"))
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        find.target = nil
        let findNext = bind(.findNext, item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g"))
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        findNext.target = nil
        let findPrev = bind(.findPrevious, item("Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift]))
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue
        findPrev.target = nil
        let copy = bind(.copy, item("Copy", #selector(NSText.copy(_:)), "c"))
        copy.target = nil
        let paste = bind(.paste, item("Paste", #selector(NSText.paste(_:)), "v"))
        paste.target = nil
        let selectAll = bind(.selectAll, item("Select All", #selector(NSText.selectAll(_:)), "a"))
        selectAll.target = nil
        main.addItem(menu("Edit", items: [copy, paste, selectAll, .separator(), find, findNext, findPrev]))
        main.addItem(menu("View", items: [
            bind(.focusLeft, arrowItem("Focus Left", #selector(focusDirectional(_:)), .left, [.command, .option], 1)),
            bind(.focusRight, arrowItem("Focus Right", #selector(focusDirectional(_:)), .right, [.command, .option], 2)),
            bind(.focusUp, arrowItem("Focus Up", #selector(focusDirectional(_:)), .up, [.command, .option], 3)),
            bind(.focusDown, arrowItem("Focus Down", #selector(focusDirectional(_:)), .down, [.command, .option], 4)),
            .separator(),
            bind(.growLeft, arrowItem("Grow Left", #selector(resizeDirectional(_:)), .left, [.command, .shift], 1)),
            bind(.growRight, arrowItem("Grow Right", #selector(resizeDirectional(_:)), .right, [.command, .shift], 2)),
            bind(.growUp, arrowItem("Grow Up", #selector(resizeDirectional(_:)), .up, [.command, .shift], 3)),
            bind(.growDown, arrowItem("Grow Down", #selector(resizeDirectional(_:)), .down, [.command, .shift], 4)),
            .separator(),
            bind(.fill, item("Fill Window", #selector(toggleMaximize), "\r")),
            bind(.equalize, item("Equalize Splits", #selector(equalizeSplits), "e", [.command, .shift])),
            bind(.nextLayout, item("Next Layout", #selector(cycleLayoutForward), "l", [.command, .shift])),
            bind(.previousLayout, item("Previous Layout", #selector(cycleLayoutBackward), "l", [.command, .option, .shift])),
            item("Tile Columns", #selector(tileColumns), ""),
            item("Tile Rows", #selector(tileRows), ""),
            item("Tile Grid", #selector(tileGrid), ""),
            item("Arrange Windows", #selector(arrangeWindows), ""),
            bind(.broadcast, item("Broadcast Keys", #selector(toggleBroadcast), "b")),
            .separator(),
            bind(.fontUp, item("Bigger", #selector(fontUp), "+")),
            bind(.fontDown, item("Smaller", #selector(fontDown), "-")),
            bind(.fontReset, item("Actual Size", #selector(fontReset), "0")),
        ]))
        main.addItem(menu("Window", items: [
            responderItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            responderItem("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            bind(.launch, item("Launch…", #selector(showPalette), "k")),
            bind(.insertPath, item("Insert Path…", #selector(insertPath), "p", [.command, .shift])),
            item("Dropdown Terminal", #selector(showDropdown), ""),
        ]))
        main.addItem(menu("Help", items: [
            item("Keyboard Shortcuts", #selector(showShortcuts), ""),
        ]))
        for entry in main.items {
            entry.submenu?.items.forEach { menuItem in
                if menuItem.target == nil, menuItem.action != nil, !isResponderAction(menuItem.action) {
                    menuItem.target = self
                }
            }
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.first { $0.title == "Window" }?.submenu
    }

    private func isResponderAction(_ action: Selector?) -> Bool {
        guard let action else { return false }
        let names = ["copy:", "paste:", "selectAll:", "performTextFinderAction:", "performClose:", "performMiniaturize:", "performZoom:", "terminate:"]
        return names.contains(NSStringFromSelector(action))
    }

    private func menu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func bind(_ action: AppAction, _ menuItem: NSMenuItem) -> NSMenuItem {
        boundMenus[action] = menuItem
        return menuItem
    }

    private func applyKeyBindings() {
        let map = model.settings.keys
        for (action, menuItem) in boundMenus {
            let chord = map.chord(action)
            menuItem.keyEquivalent = chord.key
            menuItem.keyEquivalentModifierMask = chord.key.isEmpty ? [] : chord.flags
        }
        HotkeyCenter.apply(enabled: model.settings.dropdownEnabled && !System.isDev, chord: map.chord(.dropdown))
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit Aether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.keyEquivalentModifierMask = [.command]
        item.target = NSApp
        return item
    }

    private func responderItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = self.item(title, action, key, modifiers)
        item.target = nil
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        return item
    }

    private func arrowItem(_ title: String, _ action: Selector, _ arrow: Direction, _ modifiers: NSEvent.ModifierFlags, _ tag: Int) -> NSMenuItem {
        let key: String
        switch arrow {
        case .left: key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .right: key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .up: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .down: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        item.target = self
        return item
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Aether",
            .applicationVersion: BuildStamp.current.version,
            .version: BuildStamp.current.shortCommit,
            .credits: NSAttributedString(string: "A native macOS terminal. Each pane is a real shell, and the glass refracts whatever is behind the window."),
        ])
    }

    @objc private func showSettings() { settingsPanel.show() }
    @objc private func showShortcuts() { shortcuts.show() }
    @objc private func showPalette() { palette.show(); finish(.launch) }
    @objc private func insertPath() { PathInsert.show(); finish(.insertPath) }
    @objc private func showDropdown() { model.toggleDropdown() }
    @objc private func newWindow() { model.newWindow(); finish(.newWindow) }
    @objc private func newPane() { model.newPane(); finish(.newPane) }
    @objc private func splitRight() { model.splitFocused(.right); finish(.splitRight) }
    @objc private func splitDown() { model.splitFocused(.bottom); finish(.splitDown) }
    @objc private func closePane() {
        if NSApp.keyWindow === palette.window {
            palette.vaporize()
            return
        }
        if NSApp.keyWindow === settingsPanel.window {
            settingsPanel.vaporize()
            return
        }
        if NSApp.keyWindow === shortcuts.window {
            shortcuts.vaporize()
            return
        }
        closeFocusedPane()
    }
    @objc private func toggleMaximize() { model.toggleMaximize(); finish(.fill) }
    @objc private func equalizeSplits() { model.equalize(); finish(.equalize) }

    private func finish(_ action: AppAction) {
        guard let raw = model.settings.keys.chord(action).follow, let next = AppAction(rawValue: raw), next != action else { return }
        switch next {
        case .newWindow: model.newWindow()
        case .newPane: model.newPane()
        case .splitRight: model.splitFocused(.right)
        case .splitDown: model.splitFocused(.bottom)
        case .equalize: model.equalize()
        case .fill: model.toggleMaximize()
        case .nextLayout: model.cycleLayout(by: 1)
        case .insertPath: PathInsert.show()
        default: break
        }
    }
    @objc private func cycleLayoutForward() { model.cycleLayout(by: 1) }
    @objc private func cycleLayoutBackward() { model.cycleLayout(by: -1) }
    @objc private func tileColumns() { model.arrange(.columns) }
    @objc private func tileRows() { model.arrange(.rows) }
    @objc private func tileGrid() { model.arrange(.grid) }
    @objc private func arrangeWindows() { model.arrangeWindows() }
    @objc private func toggleBroadcast() { model.toggleBroadcast() }
    @objc private func fontUp() { model.changeFont(by: 1) }
    @objc private func fontDown() { model.changeFont(by: -1) }
    @objc private func fontReset() { model.changeFont(by: 0) }

    @objc private func focusDirectional(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: model.focus(.left)
        case 2: model.focus(.right)
        case 3: model.focus(.up)
        case 4: model.focus(.down)
        default: break
        }
    }

    @objc private func resizeDirectional(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: model.nudge(.left)
        case 2: model.nudge(.right)
        case 3: model.nudge(.up)
        case 4: model.nudge(.down)
        default: break
        }
    }
}

final class SmokeStripes: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [
            NSColor(srgbRed: 0.95, green: 0.18, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.12, green: 0.45, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.78, blue: 0.38, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.76, blue: 0.16, alpha: 1),
            NSColor(srgbRed: 0.58, green: 0.22, blue: 0.9, alpha: 1),
        ]
        let width = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(index) * width, y: 0, width: width + 1, height: bounds.height)).fill()
        }
    }
}
