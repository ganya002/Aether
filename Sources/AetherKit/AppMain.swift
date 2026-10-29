import AppKit
import Carbon.HIToolbox

@MainActor
public enum AetherApplication {
    private static let delegate = AppDelegate()

    public static func launch() {
        // A write to a socket or pipe whose reader is gone (an agent that hung up mid-reply,
        // a hook that quit early) should fail with EPIPE, not kill every terminal at once.
        signal(SIGPIPE, SIG_IGN)
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
    private var statusItem: NSStatusItem?

    static let helpURL = URL(string: "https://github.com/ganya002/Aether#readme")!
    static let issueURL = URL(string: "https://github.com/ganya002/Aether/issues/new")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The View menu has its own Enter Full Screen item.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        palette.onPick = { [weak self] row in
            self?.perform(row)
        }
        shortcuts.onCustomize = { [weak self] in
            self?.settingsPanel.show()
        }
        buildMenus()
        if ProcessInfo.processInfo.environment["AETHER_RELAUNCHED"] == "1" {
            // Restarted by an update from a background shell: come forward with the restored windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.activate()
            }
        }
        FinishNotifier.install()
        AetherTerminal.cleanDropStash()
        LocalNetworkAccess.start()
        ToolShelf.shared.warm()
        NotificationCenter.default.addObserver(forName: .aetherBindingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyKeyBindings()
                self?.refreshStatusItem()
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
        refreshStatusItem()
        SecureKeyboard.restore()
        NSApp.activate(ignoringOtherApps: true)
        showOnboarding()
        UpdateDemo.autoplay()
        guard !System.isDev else { return }
        offerMoveToApplications()
        UpdateCenter.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !System.isDev else { return }
        UpdateCenter.shared.checkSoon()
    }

    // MARK: First run

    private static let neverMoveKey = "aether.neverAskToMoveToApplications"

    /// The curl installer leaves Aether in Downloads and launches it. Offer to move it until
    /// it lives in Applications or the person says not to ask again.
    private func offerMoveToApplications() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let path = bundle.standardizedFileURL.path
        let homes = [
            "/Applications/",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/",
        ]
        if homes.contains(where: { path.hasPrefix($0) }) { return }
        guard !UserDefaults.standard.bool(forKey: Self.neverMoveKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let window = self.model.keyWindowForSheets
                ?? self.model.controllers.values.compactMap(\.window).first { $0.isVisible }
            let alert = NSAlert()
            alert.messageText = "Move Aether to Applications?"
            alert.informativeText = "Aether is running from \(bundle.deletingLastPathComponent().lastPathComponent). In Applications, Spotlight and the Dock can find it, and updates install cleanly."
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Not Now")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(true, forKey: Self.neverMoveKey)
                }
                if response == .alertFirstButtonReturn {
                    self.moveToApplications(bundle, window: window)
                }
            }
            if let window, window.attachedSheet == nil {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                finish(alert.runModal())
            }
        }
    }

    private func moveToApplications(_ bundle: URL, window: NSWindow?) {
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundle.lastPathComponent)
        let files = FileManager.default
        do {
            if files.fileExists(atPath: destination.path) {
                let open = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .contains { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
                if open {
                    explain("Another Aether is open from Applications", "Quit it, then choose Move to Applications again.", window: window)
                    return
                }
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            try files.moveItem(at: bundle, to: destination)
        } catch {
            explain("Aether couldn't move itself", "\(error.localizedDescription) Drag Aether.app into Applications in Finder instead.", window: window) {
                NSWorkspace.shared.activateFileViewerSelecting([bundle])
            }
            return
        }
        // Wait for this copy to quit, then open the moved one.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"",
            destination.path,
        ]
        do {
            try relaunch.run()
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return
        }
        // Moving was the person's answer, so quitting does not ask again.
        model.quitConfirmed = true
        NSApp.terminate(nil)
        model.quitConfirmed = false
    }

    private func explain(_ title: String, _ detail: String, window: NSWindow?, then: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { _ in then?() }
        } else {
            alert.runModal()
            then?()
        }
    }

    private func showOnboarding() {
        guard OnboardingStrip.wanted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let deskID = self.model.keyDeskID, let desk = self.model.desks[deskID] else { return }
            guard let first = Layout.visualIDs(desk.layout).first, let pane = self.model.panes[first] else { return }
            OnboardingStrip.attach(to: pane.chrome)
        }
    }

    // MARK: Menu bar extra

    /// With the Dock icon hidden, the menu bar extra is the way back to Aether.
    private func refreshStatusItem() {
        let wanted = model.settings.hideDockIcon
        if !wanted {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "Aether")
        item.button?.setAccessibilityLabel("Aether")
        let menu = NSMenu()
        menu.addItem(statusEntry("New Window", .newWindow))
        menu.addItem(statusEntry("Dropdown Terminal", .dropdown))
        menu.addItem(.separator())
        menu.addItem(statusEntry("Settings…", .settings))
        menu.addItem(.separator())
        menu.addItem(quitItem())
        item.menu = menu
        statusItem = item
    }

    private func statusEntry(_ title: String, _ action: AppAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runFromStatusItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        return item
    }

    @objc private func runFromStatusItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = AppAction(rawValue: raw) else { return }
        if action != .dropdown {
            NSApp.activate(ignoringOtherApps: true)
        }
        perform(action)
    }

    // MARK: Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let question = model.quitQuestion() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if let window = model.keyWindowForSheets, window.isVisible {
            if let sheet = window.attachedSheet {
                // Logging out or shutting down must not stall on a question nobody is answering.
                if Self.quitBySystem { return .terminateNow }
                window.makeKeyAndOrderFront(nil)
                sheet.makeKeyAndOrderFront(nil)
                NSSound.beep()
                return .terminateCancel
            }
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { response in
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// True when the quit comes from logging out, restarting, or shutting down.
    private static var quitBySystem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        let system = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        return system.map { OSType($0) }.contains(reason)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reopen()
        return false
    }

    // MARK: Validation

    private var auxiliaryIsKey: Bool {
        NSApp.keyWindow === palette.window || NSApp.keyWindow === settingsPanel.window || NSApp.keyWindow === shortcuts.window
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSecureKeyboardEntry):
            menuItem.state = SecureKeyboard.isOn ? .on : .off
            return true
        case #selector(chooseLayout(_:)):
            let kind = (menuItem.representedObject as? String).flatMap(LayoutKind.init(rawValue:))
            menuItem.state = kind != nil && model.keyLayoutKind == kind ? .on : .off
            return model.keyDeskID != nil && !auxiliaryIsKey
        case #selector(runAction(_:)):
            guard let raw = menuItem.representedObject as? String, let action = AppAction(rawValue: raw) else { return true }
            return isAvailable(action, menuItem)
        default:
            return true
        }
    }

    private func isAvailable(_ action: AppAction, _ menuItem: NSMenuItem) -> Bool {
        let desk = model.keyDeskID
        switch action {
        case .broadcast:
            menuItem.state = model.keyBroadcast ? .on : .off
            return desk != nil
        case .dropdown:
            return model.settings.dropdownEnabled
        case .closePane:
            return desk != nil || auxiliaryIsKey || PathInsert.isKey
        case .fill:
            return desk != nil && !auxiliaryIsKey
        case .splitRight, .splitDown, .clearBuffer, .equalize, .nextLayout, .previousLayout,
             .focusLeft, .focusRight, .focusUp, .focusDown, .growLeft, .growRight, .growUp, .growDown,
             .renamePane, .restartPane, .find, .insertPath:
            return desk != nil
        case .previousPane, .nextPane, .swapNext:
            return model.keyPaneOrder.count > 1
        case .movePaneToWindow:
            return model.keyPaneOrder.count > 1 || (desk.flatMap { model.desks[$0]?.tabs.count } ?? 0) > 1
        case .nextTab, .previousTab:
            return (desk.flatMap { model.desks[$0]?.tabs.count } ?? 0) > 1
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            return (action.paneNumber ?? 99) <= model.keyPaneOrder.count
        default:
            return true
        }
    }

    // MARK: Actions

    private func perform(_ row: PaletteRow) {
        switch row.kind {
        case .command(let command, let newWindow):
            LauncherRecents.remember(command)
            if newWindow { model.newWindow(command: command) } else { model.newPane(command: command) }
        case .tool(let name):
            LauncherRecents.remember(name)
            model.newPane(command: name)
        case .action(let action):
            switch action {
            case .app(let app): perform(app)
            case .layout(let kind): model.arrange(kind)
            case .arrangeWindows: model.arrangeWindows()
            case .checkForUpdates: checkForUpdates()
            case .openConfig: UserConfigCenter.shared.openFile()
            case .glass(let style): model.updateSettings { $0.glass = style }
            case .help: openHelp()
            case .giveAllPermissions: PermissionGrant.present(from: NSApp.keyWindow)
            case .saveWorkspace: model.promptSaveWorkspace()
            case .openWorkspace(let name): model.openWorkspace(name)
            case .renameWorkspace(let name): model.promptRenameWorkspace(name)
            case .deleteWorkspace(let name): model.confirmDeleteWorkspace(name)
            }
        }
    }

    /// Every bound action runs through here: menus, the launcher, and the menu bar extra.
    private func perform(_ action: AppAction, chained: Bool = false) {
        switch action {
        case .newWindow: model.newWindow()
        case .newPane: model.newPane()
        case .newTab: model.newTab()
        case .closeTab: model.closeActiveTab()
        case .nextTab: model.cycleTab(by: 1)
        case .previousTab: model.cycleTab(by: -1)
        case .splitRight: model.splitFocused(.right)
        case .splitDown: model.splitFocused(.bottom)
        case .closePane: closePane()
        case .closeWindow: (NSApp.keyWindow ?? model.keyWindowForSheets)?.performClose(nil)
        case .launch: palette.show()
        case .clearBuffer: model.clearBuffer()
        case .fill: model.toggleMaximize()
        case .equalize: model.equalize()
        case .nextLayout: model.cycleLayout(by: 1)
        case .previousLayout: model.cycleLayout(by: -1)
        case .focusLeft: model.focus(.left)
        case .focusRight: model.focus(.right)
        case .focusUp: model.focus(.up)
        case .focusDown: model.focus(.down)
        case .growLeft: model.nudge(.left)
        case .growRight: model.nudge(.right)
        case .growUp: model.nudge(.up)
        case .growDown: model.nudge(.down)
        case .broadcast: model.toggleBroadcast()
        case .fontUp: model.changeFont(by: 1)
        case .fontDown: model.changeFont(by: -1)
        case .fontReset: model.changeFont(by: 0)
        case .find: showFind()
        case .findNext: textFinder(.nextMatch)
        case .findPrevious: textFinder(.previousMatch)
        case .copy: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case .paste: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case .selectAll: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case .settings: settingsPanel.show()
        case .dropdown: model.toggleDropdown()
        case .quit: NSApp.terminate(nil)
        case .insertPath: PathInsert.show()
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            model.focusPane(number: action.paneNumber ?? 1)
        case .previousPane: model.cyclePane(by: -1)
        case .nextPane: model.cyclePane(by: 1)
        case .swapNext: model.swapWithNext()
        case .movePaneToWindow: model.moveToNewWindow()
        case .renamePane:
            if let id = focusedPaneID { RenameSheet.present(paneID: id) }
        case .restartPane:
            if let id = focusedPaneID { model.restart(id) }
        case .shortcuts: shortcuts.show()
        case .copyMode:
            if let id = focusedPaneID, let pane = model.panes[id] { pane.chrome.terminal.toggleCopyMode() }
        case .previousPrompt, .nextPrompt, .selectLastOutput:
            if let id = focusedPaneID, let pane = model.panes[id], !pane.chrome.terminal.performPromptAction(action) {
                NSSound.beep()
            }
        }
        guard !chained else { return }
        // A shortcut can be set to run a second action after its own.
        guard let raw = model.settings.keys.chord(action).follow, let next = AppAction(rawValue: raw), next != action else { return }
        perform(next, chained: true)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = AppAction(rawValue: raw) else { return }
        perform(action)
    }

    private var focusedPaneID: String? {
        guard let deskID = model.keyDeskID else { return nil }
        return model.desks[deskID]?.focusedID
    }

    private func closePane() {
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
        if PathInsert.isKey {
            PathInsert.dismiss()
            return
        }
        guard let id = focusedPaneID else { return }
        model.closePane(id)
    }

    private func showFind() {
        guard let deskID = model.keyDeskID, let focused = model.desks[deskID]?.focusedID, let pane = model.panes[focused] else { return }
        model.controllers[deskID]?.window?.makeKeyAndOrderFront(nil)
        model.controllers[deskID]?.window?.makeFirstResponder(pane.chrome.terminal)
        textFinder(.showFindInterface)
    }

    private func textFinder(_ action: NSTextFinder.Action) {
        guard let id = focusedPaneID, let pane = model.panes[id] else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: pane.chrome.terminal, from: item)
    }

    private func checkForUpdates() {
        Task { @MainActor in
            let message = await UpdateCenter.shared.checkNow()
            // The update card shows every other answer.
            guard message == UpdateCenter.devBuild, let deskID = self.model.keyDeskID else { return }
            self.model.controllers[deskID]?.flashLayout(message)
        }
    }

    private func openHelp() {
        NSWorkspace.shared.open(Self.helpURL)
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

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        let secure = NSMenuItem(title: "Secure Keyboard Entry", action: #selector(toggleSecureKeyboardEntry), keyEquivalent: "")
        secure.target = self
        main.addItem(menu("Aether", items: [
            plain("About Aether", #selector(showAbout)),
            .separator(),
            bind(.settings, item("Settings…", .settings)),
            plain("Check for Updates…", #selector(checkForUpdatesPressed)),
            plain("Give All Permissions…", #selector(giveAllPermissionsPressed)),
            .separator(),
            secure,
            .separator(),
            servicesItem,
            .separator(),
            appItem("Hide Aether", #selector(NSApplication.hide(_:)), "h", [.command]),
            appItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            appItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", []),
            .separator(),
            bind(.quit, quitItem()),
        ]))

        main.addItem(menu("Shell", items: [
            bind(.newWindow, item("New Window", .newWindow)),
            bind(.newPane, item("New Terminal", .newPane)),
            bind(.newTab, item("New Tab", .newTab)),
            bind(.closeTab, item("Close Tab", .closeTab)),
            .separator(),
            bind(.launch, item("Launch…", .launch)),
            bind(.insertPath, item("Insert Path…", .insertPath)),
            .separator(),
            bind(.splitRight, item("Split Right", .splitRight)),
            bind(.splitDown, item("Split Down", .splitDown)),
            .separator(),
            bind(.renamePane, item("Rename Terminal…", .renamePane)),
            bind(.swapNext, item("Swap with Next Terminal", .swapNext)),
            bind(.movePaneToWindow, item("Move Terminal to New Window", .movePaneToWindow)),
            bind(.restartPane, item("Restart Terminal", .restartPane)),
            .separator(),
            bind(.closePane, item("Close Terminal", .closePane)),
            bind(.closeWindow, responderItem("Close Window", #selector(NSWindow.performClose(_:)))),
        ]))

        let find = bind(.find, responderItem("Find…", #selector(NSResponder.performTextFinderAction(_:))))
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findNext = bind(.findNext, responderItem("Find Next", #selector(NSResponder.performTextFinderAction(_:))))
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPrev = bind(.findPrevious, responderItem("Find Previous", #selector(NSResponder.performTextFinderAction(_:))))
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue
        let useSelection = responderItem("Use Selection for Find", #selector(NSResponder.performTextFinderAction(_:)), "e", [.command])
        useSelection.tag = NSTextFinder.Action.setSearchString.rawValue
        main.addItem(menu("Edit", items: [
            responderItem("Undo", Selector(("undo:")), "z", [.command]),
            responderItem("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            responderItem("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            bind(.copy, responderItem("Copy", #selector(NSText.copy(_:)))),
            bind(.paste, responderItem("Paste", #selector(NSText.paste(_:)))),
            bind(.selectAll, responderItem("Select All", #selector(NSText.selectAll(_:)))),
            .separator(),
            bind(.clearBuffer, item("Clear Scrollback", .clearBuffer)),
            .separator(),
            bind(.previousPrompt, item("Previous Prompt", .previousPrompt)),
            bind(.nextPrompt, item("Next Prompt", .nextPrompt)),
            bind(.selectLastOutput, item("Select Last Command Output", .selectLastOutput)),
            bind(.copyMode, item("Copy Mode", .copyMode)),
            .separator(),
            menu("Find", items: [find, findNext, findPrev, .separator(), useSelection]),
        ]))

        var layouts = LayoutKind.cycle.map { kind -> NSMenuItem in
            let entry = NSMenuItem(title: kind.title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = kind.rawValue
            return entry
        }
        layouts += [
            .separator(),
            bind(.nextLayout, item("Next Layout", .nextLayout)),
            bind(.previousLayout, item("Previous Layout", .previousLayout)),
        ]
        var focus: [NSMenuItem] = [
            bind(.focusLeft, item("Focus Left", .focusLeft)),
            bind(.focusRight, item("Focus Right", .focusRight)),
            bind(.focusUp, item("Focus Up", .focusUp)),
            bind(.focusDown, item("Focus Down", .focusDown)),
            .separator(),
            bind(.previousPane, item("Previous Terminal", .previousPane)),
            bind(.nextPane, item("Next Terminal", .nextPane)),
            bind(.previousTab, item("Previous Tab", .previousTab)),
            bind(.nextTab, item("Next Tab", .nextTab)),
            .separator(),
        ]
        for number in 1...9 {
            guard let action = AppAction.focusPane(number) else { continue }
            focus.append(bind(action, item("Terminal \(number)", action)))
        }
        let fullScreen = responderItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        main.addItem(menu("View", items: [
            menu("Layout", items: layouts),
            menu("Focus", items: focus),
            menu("Resize", items: [
                bind(.growLeft, item("Grow Left", .growLeft)),
                bind(.growRight, item("Grow Right", .growRight)),
                bind(.growUp, item("Grow Up", .growUp)),
                bind(.growDown, item("Grow Down", .growDown)),
                .separator(),
                bind(.equalize, item("Equalize Splits", .equalize)),
            ]),
            bind(.fill, item("Fill Window", .fill)),
            .separator(),
            bind(.fontUp, item("Bigger", .fontUp)),
            bind(.fontDown, item("Smaller", .fontDown)),
            bind(.fontReset, item("Actual Size", .fontReset)),
            .separator(),
            bind(.broadcast, item("Broadcast Keys", .broadcast)),
            .separator(),
            fullScreen,
        ]))

        let windowMenu = menu("Window", items: [
            responderItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", [.command]),
            responderItem("Zoom", #selector(NSWindow.performZoom(_:)), "", []),
            .separator(),
            bind(.dropdown, item("Dropdown Terminal", .dropdown)),
            appItem("Arrange Windows", #selector(arrangeWindows), "", []),
            .separator(),
            appItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", []),
        ])
        main.addItem(windowMenu)

        let helpMenu = menu("Help", items: [
            bind(.shortcuts, item("Keyboard Shortcuts", .shortcuts)),
            .separator(),
            plain("Aether Help", #selector(helpPressed)),
            plain("Report an Issue…", #selector(reportIssue)),
        ])
        main.addItem(helpMenu)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.helpMenu = helpMenu.submenu
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

    /// A bound action. Its key equivalent comes from the key map.
    private func item(_ title: String, _ action: AppAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.representedObject = action.rawValue
        item.target = self
        return item
    }

    private func plain(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Sent along the responder chain, to the terminal or window that has focus.
    private func responderItem(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = nil
        return item
    }

    private func appItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = action == #selector(arrangeWindows) ? self : NSApp
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

    @objc private func checkForUpdatesPressed() { checkForUpdates() }
    @objc private func giveAllPermissionsPressed() { PermissionGrant.present(from: NSApp.keyWindow) }
    @objc private func helpPressed() { openHelp() }
    @objc private func reportIssue() { NSWorkspace.shared.open(Self.issueURL) }
    @objc private func arrangeWindows() { model.arrangeWindows() }
    @objc private func toggleSecureKeyboardEntry() { SecureKeyboard.toggle() }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = LayoutKind(rawValue: raw) else { return }
        model.arrange(kind)
    }
}

/// Secure Keyboard Entry, as in Terminal.app: other apps cannot watch what is typed.
@MainActor
enum SecureKeyboard {
    static let key = "aether.secureKeyboardEntry"
    private(set) static var isOn = false

    static func restore() {
        if UserDefaults.standard.bool(forKey: key) { set(true) }
    }

    static func toggle() {
        set(!isOn)
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        guard on != isOn else { return }
        if on { EnableSecureEventInput() } else { DisableSecureEventInput() }
        isOn = on
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
