import AppKit
import Darwin
import Foundation

struct PaneState: Codable, Equatable {
    var id: String
    var cwd: String
    var command: String?
    var title: String
    var exitCode: Int32?
}

struct Desk: Equatable {
    var id: String
    var layout: LayoutNode
    var kind: LayoutKind
    var focusedID: String
    var maximizedID: String?
    var broadcast: Bool
    var dropdown: Bool = false
    var frame: CGRect
    var panes: [String: PaneState]
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    private(set) var settings = Settings()
    private(set) var desks: [String: Desk] = [:]
    private(set) var panes: [String: PaneController] = [:]
    private(set) var controllers: [String: DeskController] = [:]
    private var order: [String] = []
    private var saveItem: DispatchWorkItem?
    private var directoryTimer: Timer?
    private var closing: Set<String> = []
    private var lastKeyDesk: String?
    private var dropdownID: String?
    private var busySince: [String: (date: Date, command: String)] = [:]
    private var lazySaveItem: DispatchWorkItem?
    private var confirmedDeskClose: Set<String> = []
    private var asking: Set<String> = []

    private init() {
        directoryTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
            Task { @MainActor in
                AppModel.shared.refreshDirectories()
            }
        }
    }

    var keyDeskID: String? {
        if let window = NSApp.keyWindow {
            for (id, controller) in controllers where controller.window === window {
                lastKeyDesk = id
                return id
            }
        }
        if let lastKeyDesk, desks[lastKeyDesk] != nil, controllers[lastKeyDesk]?.window?.isVisible == true {
            return lastKeyDesk
        }
        return order.last { controllers[$0]?.window?.isVisible == true }
    }

    func noteKey(_ deskID: String) {
        lastKeyDesk = deskID
    }

    func restoreOrCreate() {
        let snapshot = SessionStore.load()
        if let snapshot {
            settings = snapshot.settings
        }
        let portable = ConfigStore.load()
        if let portable {
            settings = portable
        }
        settings.clamp()
        if portable == nil, (snapshot?.version ?? 0) < Settings.currentVersion, settings.glass == .clear {
            settings.glass = .regular
        }
        if let snapshot {
            for saved in snapshot.desks {
                restore(saved)
            }
        }
        if desks.isEmpty {
            newWindow()
        }
        ConfigStore.save(settings)
        applyDock()
        if settings.notifyOnFinish {
            FinishNotifier.requestQuietPermissionIfUndecided()
        }
        if let moved = ConfigStore.quarantined {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let alert = NSAlert()
                alert.messageText = "Aether couldn't read its settings"
                alert.informativeText = "config.json wasn't valid JSON, so Aether started with default settings. The old file is saved as \(moved.lastPathComponent) in the same folder."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([moved])
                }
            }
        }
    }

    func newWindow(command: String? = nil, cwd: String? = nil, frame: CGRect? = nil) {
        let directory = cwd ?? focusedDirectory() ?? System.home()
        let id = UUID().uuidString
        let paneID = UUID().uuidString
        let resolved = frame ?? cascadedFrame()
        let desk = Desk(
            id: id,
            layout: .pane(paneID),
            kind: .tall,
            focusedID: paneID,
            maximizedID: nil,
            broadcast: false,
            frame: resolved,
            panes: [paneID: PaneState(id: paneID, cwd: directory, command: command, title: Self.initialTitle(command: command, cwd: directory), exitCode: nil)]
        )
        desks[id] = desk
        order.append(id)
        let controller = makeController(desk)
        makePane(desk.panes[paneID]!, settings: settings)
        controller.sync()
        controller.presentAnimated()
        startSoon(paneID)
        scheduleSave()
    }

    func toggleDropdown() {
        guard settings.dropdownEnabled else { return }
        if let id = dropdownID, let controller = controllers[id] {
            if controller.window?.isVisible == true, (controller.window?.alphaValue ?? 0) > 0.4 {
                controller.dismissDropdown()
            } else {
                controller.presentDropdown()
            }
            return
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(980, screen.width - 36)
        let height = min(460, max(320, screen.height * 0.44))
        let frame = CGRect(x: screen.midX - width / 2, y: screen.maxY - height - 8, width: width, height: height)
        let id = UUID().uuidString
        let paneID = UUID().uuidString
        let directory = focusedDirectory() ?? System.home()
        var desk = Desk(
            id: id,
            layout: .pane(paneID),
            kind: .tall,
            focusedID: paneID,
            maximizedID: nil,
            broadcast: false,
            frame: frame,
            panes: [paneID: PaneState(id: paneID, cwd: directory, command: nil, title: Self.initialTitle(command: nil, cwd: directory), exitCode: nil)]
        )
        desk.dropdown = true
        desks[id] = desk
        order.append(id)
        dropdownID = id
        let controller = makeController(desk)
        makePane(desk.panes[paneID]!, settings: settings)
        controller.sync()
        controller.presentDropdown()
        startSoon(paneID)
    }

    func noteDropdownHidden(_ deskID: String) {
        guard dropdownID == deskID, lastKeyDesk == deskID else { return }
        lastKeyDesk = order.last { $0 != deskID && controllers[$0]?.window?.isVisible == true }
        if let lastKeyDesk, let window = controllers[lastKeyDesk]?.window {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func newPane(command: String? = nil, cwd: String? = nil) {
        guard let deskID = keyDeskID, var desk = desks[deskID] else {
            newWindow(command: command, cwd: cwd)
            return
        }
        let directory = cwd ?? desk.panes[desk.focusedID]?.cwd ?? System.home()
        let paneID = UUID().uuidString
        let previous = desk.focusedID
        var ids = Layout.visualIDs(desk.layout)
        ids.append(paneID)
        desk.focusedID = paneID
        desk.maximizedID = nil
        desk.panes[paneID] = PaneState(id: paneID, cwd: directory, command: command, title: Self.initialTitle(command: command, cwd: directory), exitCode: nil)
        if desk.kind == .splits {
            desk.layout = Layout.insert(desk.layout, target: previous, zone: .right, newID: paneID)
        } else {
            desk.layout = Self.layout(for: ids, kind: desk.kind)
        }
        desks[deskID] = desk
        makePane(desk.panes[paneID]!, settings: settings)
        controllers[deskID]?.sync(animated: true)
        startSoon(paneID)
        scheduleSave()
    }

    func splitFocused(_ zone: Zone, command: String? = nil) {
        guard let deskID = keyDeskID, var desk = desks[deskID] else {
            newWindow(command: command)
            return
        }
        let directory = desk.panes[desk.focusedID]?.cwd ?? System.home()
        let paneID = UUID().uuidString
        desk.kind = .splits
        desk.layout = Layout.insert(desk.layout, target: desk.focusedID, zone: zone, newID: paneID)
        desk.focusedID = paneID
        desk.maximizedID = nil
        desk.panes[paneID] = PaneState(id: paneID, cwd: directory, command: command, title: Self.initialTitle(command: command, cwd: directory), exitCode: nil)
        desks[deskID] = desk
        makePane(desk.panes[paneID]!, settings: settings)
        controllers[deskID]?.sync(animated: true)
        startSoon(paneID)
        scheduleSave()
    }

    func closePane(_ paneID: String, confirm: Bool = true) {
        if confirm, let pane = panes[paneID], let question = closeQuestion(for: [pane]) {
            let window = deskID(containing: paneID).flatMap { controllers[$0]?.window }
            ask(question, confirmTitle: "Close", key: "pane-\(paneID)", window: window) { [weak self] in
                self?.closePane(paneID, confirm: false)
            }
            return
        }
        guard let deskID = deskID(containing: paneID), var desk = desks[deskID] else { return }
        panes[paneID]?.endRemoteSession()
        panes[paneID]?.shutdown()
        panes[paneID] = nil
        desk.panes[paneID] = nil
        if desk.maximizedID == paneID { desk.maximizedID = nil }
        let remaining = Layout.visualIDs(desk.layout).filter { $0 != paneID }
        guard !remaining.isEmpty else {
            desks[deskID] = desk
            closeDesk(deskID)
            return
        }
        if desk.focusedID == paneID {
            desk.focusedID = remaining[0]
        }
        if desk.kind == .splits, let next = Layout.remove(desk.layout, paneID) {
            desk.layout = next
        } else {
            desk.layout = Self.layout(for: remaining, kind: desk.kind)
        }
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
        scheduleSave()
    }

    /// Called from windowShouldClose. True when the window may close now. Otherwise a sheet asks,
    /// and the window closes again once the user agrees.
    func allowClose(deskID: String, window: NSWindow) -> Bool {
        if confirmedDeskClose.remove(deskID) != nil { return true }
        let ids = desks[deskID]?.layout.panes ?? []
        guard let question = closeQuestion(for: ids.compactMap { panes[$0] }, window: true) else { return true }
        ask(question, confirmTitle: "Close", key: "desk-\(deskID)", window: window) { [weak self, weak window] in
            self?.confirmedDeskClose.insert(deskID)
            window?.performClose(nil)
        }
        return false
    }

    /// The question to ask before quitting, or nil to quit right away.
    func quitQuestion() -> (title: String, detail: String)? {
        let running = panes.values.filter { $0.runningCommand() != nil }
        switch settings.confirmClose {
        case .never:
            return nil
        case .whenBusy where running.isEmpty:
            return nil
        default:
            break
        }
        if running.isEmpty {
            return ("Quit Aether?", "Every terminal closes.")
        }
        if running.count == 1, let name = running.first?.runningCommand()?.name {
            return ("Quit Aether?", "`\(name)` is still running.")
        }
        return ("Quit Aether?", "\(running.count) terminals are running commands.")
    }

    var keyWindowForSheets: NSWindow? {
        keyDeskID.flatMap { controllers[$0]?.window }
    }

    private func closeQuestion(for panes: [PaneController], window: Bool = false) -> (title: String, detail: String)? {
        let live = panes.filter { !$0.exited }
        let running = live.compactMap { $0.runningCommand() }
        let noun = window ? "window" : "terminal"
        switch settings.confirmClose {
        case .never:
            return nil
        case .whenBusy where running.isEmpty:
            return nil
        case .always where live.isEmpty:
            return nil
        default:
            break
        }
        if running.isEmpty {
            return ("Close \(noun)?", "The shell will end.")
        }
        if running.count == 1, let name = running.first?.name {
            return ("Close \(noun)?", "`\(name)` is still running.")
        }
        return ("Close \(noun)?", "\(running.count) terminals are running commands.")
    }

    private func ask(_ question: (title: String, detail: String), confirmTitle: String, key: String, window: NSWindow?, then: @escaping () -> Void) {
        guard !asking.contains(key) else { return }
        if let window, window.attachedSheet != nil { return }
        asking.insert(key)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.asking.remove(key)
            if response == .alertFirstButtonReturn { then() }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func closeDesk(_ deskID: String) {
        guard !closing.contains(deskID) else { return }
        closing.insert(deskID)
        controllers[deskID]?.window?.close()
    }

    func deskWindowClosed(_ deskID: String) {
        if let desk = desks[deskID] {
            for paneID in desk.panes.keys {
                panes[paneID]?.shutdown()
                panes[paneID] = nil
            }
        }
        desks[deskID] = nil
        order.removeAll { $0 == deskID }
        if dropdownID == deskID { dropdownID = nil }
        closing.insert(deskID)
        DispatchQueue.main.async { [weak self] in
            self?.controllers[deskID] = nil
            self?.closing.remove(deskID)
            self?.scheduleSave()
        }
    }

    func focus(pane paneID: String) {
        guard let deskID = deskID(containing: paneID), var desk = desks[deskID] else { return }
        guard desk.focusedID != paneID else {
            controllers[deskID]?.canvas.refreshFocus()
            return
        }
        desk.focusedID = paneID
        desks[deskID] = desk
        controllers[deskID]?.sync()
    }

    func focus(_ direction: Direction) {
        guard let deskID = keyDeskID, var desk = desks[deskID] else { return }
        if desk.kind == .stack && desk.maximizedID == nil {
            let ids = Layout.visualIDs(desk.layout)
            guard let index = ids.firstIndex(of: desk.focusedID), ids.count > 1 else { return }
            let delta = (direction == .right || direction == .down) ? 1 : -1
            desk.focusedID = ids[(index + delta + ids.count) % ids.count]
            desks[deskID] = desk
            controllers[deskID]?.sync(animated: true)
            return
        }
        let rects = Layout.layoutRects(desk.layout)
        guard let next = Layout.neighbor(rects, id: desk.focusedID, direction: direction) else { return }
        desk.focusedID = next
        // A hidden pane can still become first responder. Showing the neighbor
        // means keystrokes never land in a shell the user cannot see.
        if desk.maximizedID != nil {
            desk.maximizedID = nil
        }
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
    }

    func nudge(_ direction: Direction) {
        guard let deskID = keyDeskID, var desk = desks[deskID], desk.maximizedID == nil else { return }
        desk.layout = Layout.nudge(desk.layout, pane: desk.focusedID, direction: direction)
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
        scheduleSave()
    }

    func toggleMaximize() {
        guard let deskID = keyDeskID, var desk = desks[deskID] else { return }
        desk.maximizedID = desk.maximizedID == desk.focusedID ? nil : desk.focusedID
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
    }

    func equalize() {
        guard let deskID = keyDeskID, var desk = desks[deskID] else { return }
        desk.layout = Layout.equalize(desk.layout)
        desk.maximizedID = nil
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
        scheduleSave()
    }

    func arrange(_ pattern: Pattern) {
        guard let kind = LayoutKind(pattern: pattern) else { return }
        guard let deskID = keyDeskID, var desk = desks[deskID] else { return }
        desk.kind = kind
        var ids = Layout.visualIDs(desk.layout)
        if let index = ids.firstIndex(of: desk.focusedID) {
            ids.remove(at: index)
            ids.insert(desk.focusedID, at: 0)
        }
        desk.layout = Self.layout(for: ids, kind: kind)
        desk.maximizedID = nil
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
        controllers[deskID]?.flashLayout(kind.title)
        scheduleSave()
    }

    func cycleLayout(by delta: Int) {
        guard let deskID = keyDeskID, var desk = desks[deskID] else { return }
        desk.kind = desk.kind.stepped(delta)
        var ids = Layout.visualIDs(desk.layout)
        if let index = ids.firstIndex(of: desk.focusedID) {
            ids.remove(at: index)
            ids.insert(desk.focusedID, at: 0)
        }
        desk.maximizedID = nil
        desk.layout = Self.layout(for: ids, kind: desk.kind)
        desks[deskID] = desk
        controllers[deskID]?.sync(animated: true)
        controllers[deskID]?.flashLayout(desk.kind.title)
        scheduleSave()
    }

    func arrangeWindows() {
        let screen = controllers[keyDeskID ?? ""]?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let ids = order.filter { desks[$0] != nil && desks[$0]?.dropdown != true }
        let rects = Layout.tidyRects(ids, gap: 0.018)
        for id in ids {
            guard let norm = rects[id], let window = controllers[id]?.window else { continue }
            let frame = CGRect(
                x: screen.minX + norm.x * screen.width,
                y: screen.maxY - (norm.y + norm.h) * screen.height,
                width: norm.w * screen.width,
                height: norm.h * screen.height
            )
            window.setFrame(frame, display: true, animate: true)
            noteFrame(id, frame)
        }
    }

    func toggleBroadcast() {
        guard let deskID = keyDeskID, var desk = desks[deskID] else { return }
        desk.broadcast.toggle()
        desks[deskID] = desk
        controllers[deskID]?.canvas.refreshFocus()
        controllers[deskID]?.flashLayout(desk.broadcast ? "Broadcast on" : "Broadcast off")
    }

    func isBroadcasting(pane paneID: String) -> Bool {
        guard let deskID = deskID(containing: paneID) else { return false }
        return desks[deskID]?.broadcast ?? false
    }

    func clearBuffer() {
        guard let deskID = keyDeskID, let focused = desks[deskID]?.focusedID else { return }
        panes[focused]?.clearBuffer()
    }

    /// Brings a pane forward, for a click on its notification.
    func reveal(pane paneID: String) {
        guard let deskID = deskID(containing: paneID), let controller = controllers[deskID] else { return }
        NSApp.activate(ignoringOtherApps: true)
        if desks[deskID]?.dropdown == true {
            controller.presentDropdown()
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
        }
        focus(pane: paneID)
    }

    var keyBroadcast: Bool {
        guard let deskID = keyDeskID else { return false }
        return desks[deskID]?.broadcast ?? false
    }

    func changeFont(by delta: Double) {
        if delta == 0 {
            settings.fontSize = settings.baseFontSize
        } else {
            settings.fontSize = Layout.clamp(settings.fontSize + delta, 10, 24)
        }
        applySettings()
    }

    func updateSettings(_ body: (inout Settings) -> Void) {
        body(&settings)
        settings.clamp()
        applySettings()
    }

    func restart(_ paneID: String) {
        guard let deskID = deskID(containing: paneID) else { return }
        panes[paneID]?.launch()
        if var desk = desks[deskID] {
            desk.panes[paneID]?.exitCode = nil
            desks[deskID] = desk
        }
    }

    func noteExit(_ paneID: String, code: Int32?) {
        guard let deskID = deskID(containing: paneID), var desk = desks[deskID] else { return }
        desk.panes[paneID]?.exitCode = code
        desks[deskID] = desk
        if let pane = panes[paneID], let started = busySince.removeValue(forKey: paneID) {
            notifyFinished(pane, command: started.command, since: started.date, exitCode: code)
        }
        if PaneController.closesOnExit(code: code, command: panes[paneID]?.command, settings: settings) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panes[paneID]?.exited == true else { return }
                self.closePane(paneID, confirm: false)
            }
        }
    }

    func refreshChrome(for paneID: String) {
        guard let pane = panes[paneID], let deskID = deskID(containing: paneID), var desk = desks[deskID] else { return }
        let moved = desk.panes[paneID]?.cwd != pane.cwd
        desk.panes[paneID]?.title = pane.title
        desk.panes[paneID]?.cwd = pane.cwd
        desks[deskID] = desk
        pane.refreshCaption(tone: settings.text)
        if desk.focusedID == paneID {
            controllers[deskID]?.window?.title = "\(pane.title) — Aether"
        }
        // Programs retitle the window constantly. Only a new directory is worth saving right away.
        if moved {
            scheduleSave()
        } else {
            scheduleLazySave()
        }
    }

    func broadcast(from paneID: String, data: ArraySlice<UInt8>) {
        guard let deskID = deskID(containing: paneID), desks[deskID]?.broadcast == true else { return }
        for other in desks[deskID]?.layout.panes ?? [] where other != paneID {
            guard let pane = panes[other], !pane.exited else { continue }
            let terminal = pane.chrome.terminal
            guard terminal.remoteSession != nil || terminal.process.running else { continue }
            terminal.deliver(data)
        }
    }

    func ratio(deskID: String, splitID: String) -> Double? {
        guard let desk = desks[deskID] else { return nil }
        return Layout.ratio(of: splitID, in: desk.layout)
    }

    func setRatio(deskID: String, splitID: String, ratio: Double) {
        guard var desk = desks[deskID] else { return }
        desk.layout = Layout.setRatio(desk.layout, splitID: splitID, ratio: ratio)
        desks[deskID] = desk
        controllers[deskID]?.sync()
    }

    func noteFrame(_ deskID: String, _ frame: CGRect) {
        desks[deskID]?.frame = frame
        scheduleSave()
    }

    func dropTarget(at screenPoint: NSPoint, dragging paneID: String) -> DropTarget? {
        let frontToBack = NSApp.orderedWindows.compactMap { window in
            controllers.first { $0.value.window === window }?.key
        }
        for deskID in frontToBack {
            guard let controller = controllers[deskID], let window = controller.window, window.frame.contains(screenPoint) else { continue }
            let local = controller.canvas.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            guard let desk = desks[deskID] else { continue }
            var best: (id: String, distance: CGFloat)?
            for id in desk.layout.panes {
                guard let frame = controller.canvas.frameOfPane(id) else { continue }
                if frame.contains(local) {
                    if id == paneID { return nil }
                    let fromTop = frame.maxY - local.y
                    let zone = Layout.zoneAt(
                        x: local.x - frame.minX,
                        y: fromTop,
                        rect: CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                    )
                    return .onto(pane: id, zone: zone)
                }
                let dx = max(frame.minX - local.x, local.x - frame.maxX, 0)
                let dy = max(frame.minY - local.y, local.y - frame.maxY, 0)
                let distance = hypot(dx, dy)
                if best == nil || distance < best!.distance {
                    best = (id, distance)
                }
            }
            if let best, best.id != paneID, best.distance < 40 {
                return .onto(pane: best.id, zone: .right)
            }
            return nil
        }
        return .detach(origin: NSPoint(x: screenPoint.x - 80, y: screenPoint.y - 300))
    }

    func showHighlight(_ target: DropTarget?, dragging paneID: String) {
        hideHighlights()
        guard case .onto(let targetID, let zone) = target, let deskID = deskID(containing: targetID) else { return }
        controllers[deskID]?.showHighlight(paneID: targetID, zone: zone)
    }

    func hideHighlights() {
        for controller in controllers.values {
            controller.hideHighlight()
        }
    }

    func performDrop(paneID: String, target: DropTarget, from sourceDeskID: String) {
        switch target {
        case .detach(let origin):
            detach(paneID, at: origin, from: sourceDeskID)
        case .onto(let targetID, let zone):
            move(paneID, onto: targetID, zone: zone)
        }
    }

    func scheduleDirectoryRefresh() {
        refreshDirectories()
    }

    func shutdownAll() {
        for pane in panes.values { pane.shutdown() }
        saveNow()
    }

    private func move(_ paneID: String, onto targetID: String, zone: Zone) {
        guard let sourceID = deskID(containing: paneID), let targetDeskID = deskID(containing: targetID) else { return }
        if sourceID == targetDeskID {
            guard var desk = desks[sourceID] else { return }
            desk.kind = .splits
            desk.layout = Layout.move(desk.layout, source: paneID, target: targetID, zone: zone)
            desk.focusedID = paneID
            desk.maximizedID = nil
            desks[sourceID] = desk
            controllers[sourceID]?.sync(animated: true)
            scheduleSave()
            return
        }
        if zone == .center {
            swap(paneID, with: targetID)
            return
        }
        guard var source = desks[sourceID], var target = desks[targetDeskID], let record = source.panes[paneID] else { return }
        source.panes[paneID] = nil
        if source.maximizedID == paneID { source.maximizedID = nil }
        let removed = Layout.remove(source.layout, paneID)
        if let removed {
            source.layout = removed
            if source.focusedID == paneID { source.focusedID = removed.panes[0] }
            desks[sourceID] = source
        } else {
            source.panes = [:]
            desks[sourceID] = source
        }
        source.kind = .splits
        target.kind = .splits
        target.layout = Layout.insert(target.layout, target: targetID, zone: zone, newID: paneID)
        target.panes[paneID] = record
        target.focusedID = paneID
        target.maximizedID = nil
        desks[sourceID] = source
        desks[targetDeskID] = target
        controllers[targetDeskID]?.sync(animated: true)
        if removed == nil {
            closeDesk(sourceID)
        } else {
            controllers[sourceID]?.sync(animated: true)
        }
        controllers[targetDeskID]?.window?.makeKeyAndOrderFront(nil)
        scheduleSave()
    }

    private func swap(_ paneID: String, with targetID: String) {
        guard let sourceID = deskID(containing: paneID), let targetDeskID = deskID(containing: targetID), sourceID != targetDeskID else { return }
        guard var source = desks[sourceID], var target = desks[targetDeskID] else { return }
        guard let sourceRecord = source.panes[paneID], let targetRecord = target.panes[targetID] else { return }
        source.kind = .splits
        target.kind = .splits
        source.layout = replace(source.layout, paneID, with: targetID)
        target.layout = replace(target.layout, targetID, with: paneID)
        source.panes[paneID] = nil
        target.panes[targetID] = nil
        source.panes[targetID] = targetRecord
        target.panes[paneID] = sourceRecord
        if source.focusedID == paneID { source.focusedID = targetID }
        if target.focusedID == targetID { target.focusedID = paneID }
        desks[sourceID] = source
        desks[targetDeskID] = target
        controllers[sourceID]?.sync(animated: true)
        controllers[targetDeskID]?.sync(animated: true)
        scheduleSave()
    }

    private func detach(_ paneID: String, at origin: CGPoint, from sourceID: String) {
        guard var source = desks[sourceID], let record = source.panes[paneID] else { return }
        if Layout.count(source.layout) < 2 {
            let screen = controllers[sourceID]?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            var frame = source.frame
            frame.origin = origin
            if let screen {
                frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
            }
            controllers[sourceID]?.window?.setFrame(frame, display: true, animate: true)
            noteFrame(sourceID, frame)
            return
        }
        guard let removed = Layout.remove(source.layout, paneID) else { return }
        source.layout = removed
        source.panes[paneID] = nil
        if source.focusedID == paneID { source.focusedID = removed.panes[0] }
        if source.maximizedID == paneID { source.maximizedID = nil }
        desks[sourceID] = source

        let deskID = UUID().uuidString
        var frame = CGRect(x: origin.x, y: origin.y, width: 680, height: 440)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.size.width = min(frame.width, screen.width - 40)
            frame.size.height = min(frame.height, screen.height - 40)
            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        }
        let desk = Desk(
            id: deskID,
            layout: .pane(paneID),
            kind: .tall,
            focusedID: paneID,
            maximizedID: nil,
            broadcast: false,
            frame: frame,
            panes: [paneID: record]
        )
        desks[deskID] = desk
        order.append(deskID)
        let controller = makeController(desk)
        controller.sync()
        controllers[sourceID]?.sync(animated: true)
        controller.presentAnimated()
        scheduleSave()
    }

    private func replace(_ node: LayoutNode, _ id: String, with replacement: String) -> LayoutNode {
        switch node {
        case .pane(let pane):
            return .pane(pane == id ? replacement : pane)
        case .split(let splitID, let axis, let ratio, let a, let b):
            return .split(id: splitID, axis: axis, ratio: ratio, a: replace(a, id, with: replacement), b: replace(b, id, with: replacement))
        }
    }

    private func restore(_ saved: SavedDesk) {
        var panes: [String: PaneState] = [:]
        for pane in saved.panes {
            panes[pane.id] = pane
        }
        let preferred = saved.maximizedID.flatMap { panes[$0] } ?? panes[saved.focusedID]
        guard let focused = preferred ?? panes.values.first else { return }
        var layout = saved.layout
        let known = Set(panes.keys)
        if !known.isSuperset(of: layout.panes) || !layout.panes.allSatisfy({ known.contains($0) }) {
            guard let rebuilt = Layout.arrange(Array(known), pattern: .columns) else { return }
            layout = rebuilt
        }
        let frame = CGRect(x: saved.x, y: saved.y, width: saved.w, height: saved.h)
        let desk = Desk(
            id: saved.id,
            layout: layout,
            kind: saved.kind ?? .splits,
            focusedID: focused.id,
            maximizedID: saved.maximizedID.flatMap { panes[$0] == nil ? nil : $0 },
            broadcast: false,
            frame: frame,
            panes: panes
        )
        desks[saved.id] = desk
        order.append(saved.id)
        let controller = makeController(desk)
        // A restored pane never runs its old command again on its own. It opens a shell where it was
        // and offers the command instead, so a `make deploy` from yesterday does not fire at launch.
        for pane in panes.values {
            var plain = pane
            plain.command = nil
            if pane.command != nil {
                plain.title = Self.initialTitle(command: nil, cwd: pane.cwd)
            }
            makePane(plain, settings: settings)
            let last = pane.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !last.isEmpty {
                self.panes[pane.id]?.offerRerun(last)
            }
        }
        for (id, pane) in panes where pane.command != nil {
            desks[saved.id]?.panes[id]?.command = nil
            desks[saved.id]?.panes[id]?.title = Self.initialTitle(command: nil, cwd: pane.cwd)
        }
        controller.sync()
        controller.showWindow(nil)
        for paneID in layout.panes {
            startSoon(paneID)
        }
    }

    private func makeController(_ desk: Desk) -> DeskController {
        let controller = DeskController(deskID: desk.id, frame: sane(desk.frame))
        controllers[desk.id] = controller
        return controller
    }

    private func makePane(_ state: PaneState, settings: Settings) {
        let pane = PaneController(id: state.id, cwd: state.cwd, command: state.command, settings: settings)
        pane.title = state.title
        panes[state.id] = pane
    }

    private func startSoon(_ paneID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pane = self.panes[paneID] else { return }
            self.controllers.values.first { $0.window?.contentView?.window != nil }?
                .window?.layoutIfNeeded()
            NSApp.windows.forEach { $0.layoutIfNeeded() }
            if let deskID = self.deskID(containing: paneID) {
                self.controllers[deskID]?.sync()
            }
            pane.launch()
            if let deskID = self.deskID(containing: paneID), self.desks[deskID]?.focusedID == paneID {
                self.controllers[deskID]?.window?.makeFirstResponder(pane.chrome.terminal)
            }
        }
    }

    private func applySettings() {
        for pane in panes.values {
            pane.apply(settings)
        }
        for controller in controllers.values {
            controller.sync()
        }
        applyDock()
        HotkeyCenter.apply(enabled: settings.dropdownEnabled && !System.isDev, chord: settings.keys.chord(.dropdown))
        UpdateCenter.shared.applyPreference()
        ConfigStore.save(settings)
        NotificationCenter.default.post(name: .aetherBindingsChanged, object: nil)
        scheduleSave()
    }

    private func applyDock() {
        let policy: NSApplication.ActivationPolicy = settings.hideDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    private func refreshDirectories() {
        for (_, pane) in panes {
            let pid = pane.chrome.terminal.process.shellPid
            guard !pane.reportsDirectory, pane.chrome.terminal.process.running, let cwd = System.currentDirectory(pid: pid) else { continue }
            if !System.sameDirectory(cwd, pane.cwd) {
                pane.noteDirectory(cwd)
            }
        }
        watchCommands()
    }

    private func watchCommands() {
        guard settings.notifyOnFinish else {
            busySince.removeAll()
            return
        }
        let now = Date()
        var live: Set<String> = []
        for (id, pane) in panes {
            live.insert(id)
            if let running = pane.runningCommand() {
                if busySince[id] == nil { busySince[id] = (now, running.line) }
                continue
            }
            // A pane whose process ended reports through noteExit, with its exit code.
            guard !pane.exited, pane.chrome.terminal.process?.running == true else { continue }
            guard let started = busySince.removeValue(forKey: id) else { continue }
            notifyFinished(pane, command: started.command, since: started.date, exitCode: nil)
        }
        busySince = busySince.filter { live.contains($0.key) }
    }

    private func notifyFinished(_ pane: PaneController, command: String, since started: Date, exitCode: Int32?) {
        guard settings.notifyOnFinish else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= settings.notifyAfterSeconds else { return }
        guard let deskID = deskID(containing: pane.id) else { return }
        let window = controllers[deskID]?.window
        let visibleHere = NSApp.isActive && window?.isKeyWindow == true && !NSApp.isHidden
        guard !visibleHere else { return }
        FinishNotifier.deliver(
            title: command,
            body: FinishNotifier.phrase(command: command, elapsed: elapsed, exitCode: exitCode),
            pane: pane.id
        )
    }

    private func focusedDirectory() -> String? {
        guard let deskID = keyDeskID, let desk = desks[deskID] else { return nil }
        return desk.panes[desk.focusedID]?.cwd
    }

    private func deskID(containing paneID: String) -> String? {
        desks.first { $0.value.panes[paneID] != nil }?.key
    }

    private func cascadedFrame() -> CGRect {
        let size = CGSize(width: 780, height: 500)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        if let previous = order.reversed().compactMap({ id -> CGRect? in
            guard desks[id]?.dropdown != true else { return nil }
            return controllers[id]?.window?.frame
        }).first {
            var frame = CGRect(origin: CGPoint(x: previous.minX + 32, y: previous.minY - 32), size: size)
            if !screen.intersects(frame) {
                frame.origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
            }
            return frame
        }
        return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func sane(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        var next = frame
        if next.width < 420 || next.height < 280 || !screen.intersects(next.insetBy(dx: 40, dy: 40)) {
            next.size = CGSize(width: 780, height: 500)
            next.origin = CGPoint(x: screen.midX - 390, y: screen.midY - 250)
        }
        next.size.width = min(max(next.width, 420), screen.width)
        next.size.height = min(max(next.height, 280), screen.height)
        next.origin.x = min(max(next.origin.x, screen.minX - 40), screen.maxX - 120)
        next.origin.y = min(max(next.origin.y, screen.minY - 40), screen.maxY - 80)
        return next
    }

    /// At most one save every few seconds, for changes that are cheap to lose.
    private func scheduleLazySave() {
        guard lazySaveItem == nil, saveItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.lazySaveItem = nil
            self?.saveNow()
        }
        lazySaveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func scheduleSave() {
        lazySaveItem?.cancel()
        lazySaveItem = nil
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveItem = nil
            self?.saveNow()
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func saveNow() {
        guard !CommandLine.arguments.contains("--smoke") else { return }
        let saved = order.compactMap { id -> SavedDesk? in
            guard let desk = desks[id], !desk.dropdown else { return nil }
            let frame = controllers[id]?.window?.frame ?? desk.frame
            return SavedDesk(
                id: desk.id,
                x: frame.minX,
                y: frame.minY,
                w: frame.width,
                h: frame.height,
                layout: desk.layout,
                focusedID: desk.focusedID,
                maximizedID: desk.maximizedID,
                kind: desk.kind,
                panes: desk.layout.panes.compactMap { desk.panes[$0] }
            )
        }
        SessionStore.save(Snapshot(version: Settings.currentVersion, settings: settings, desks: saved))
    }

    private static func initialTitle(command: String?, cwd: String) -> String {
        if let command {
            let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
            return first
        }
        let name = URL(fileURLWithPath: System.userShell()).lastPathComponent
        return name.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : name
    }
}

struct Snapshot: Codable {
    var version: Int
    var settings: Settings
    var desks: [SavedDesk]
}

struct SavedDesk: Codable {
    var id: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var layout: LayoutNode
    var focusedID: String
    var maximizedID: String?
    var kind: LayoutKind?
    var panes: [PaneState]
}

extension AppModel {
    static func layout(for ids: [String], kind: LayoutKind) -> LayoutNode {
        guard let first = ids.first else { return .pane(UUID().uuidString) }
        if ids.count == 1 { return .pane(first) }
        let pattern = kind.pattern ?? .rows
        return Layout.arrange(ids, pattern: pattern) ?? .pane(first)
    }
}

enum ConfigStore {
    static func fileURL() -> URL {
        System.supportDirectory().appendingPathComponent("config.json")
    }

    /// Where an unreadable config.json was moved this launch, so Aether can say so once.
    @MainActor static var quarantined: URL?

    /// Each setting decodes on its own, so a bad value only resets itself. A file that is not
    /// JSON at all is set aside as config.json.bad-<time> instead of being written over.
    @MainActor static func load() -> Settings? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let settings = decode(data) { return settings }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let moved = url.deletingLastPathComponent().appendingPathComponent("config.json.bad-\(stamp)")
        if (try? FileManager.default.moveItem(at: url, to: moved)) != nil {
            quarantined = moved
        }
        return nil
    }

    static func decode(_ data: Data) -> Settings? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    static func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL(), options: .atomic)
    }
}

enum SessionStore {
    static func fileURL() -> URL {
        System.supportDirectory().appendingPathComponent("session.json")
    }

    static func load() -> Snapshot? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        let url = fileURL()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension AppModel {
    func agent(path: String, body: [String: Any]) -> [String: Any] {
        switch path {
        case "/tab":
            let pane = openAgentPane(zone: nil, command: body["command"] as? String, focus: bool(body["focus"], false), share: share(body["ratio"]))
            return ["ok": true, "pane": pane]
        case "/split":
            let zone = Zone(rawValue: body["direction"] as? String ?? "right") ?? .right
            let pane = openAgentPane(zone: zone, command: body["command"] as? String, focus: bool(body["focus"], false), share: share(body["ratio"]))
            return ["ok": true, "pane": pane]
        case "/open":
            let zone = Zone(rawValue: body["direction"] as? String ?? "right") ?? .right
            let pane = openAgentPane(zone: zone, command: nil, focus: false, share: share(body["ratio"]))
            let kind = body["kind"] as? String ?? "web"
            let target = body["target"] as? String ?? ""
            guard let controller = panes[pane], controller.chrome.showPreview(kind: kind, source: target) else {
                return ["ok": false, "error": "Could not open that page."]
            }
            controller.holdsPreview = true
            return ["ok": true, "pane": pane]
        case "/font":
            let delta = (body["delta"] as? Double) ?? Double(body["delta"] as? Int ?? 1)
            changeFont(by: delta)
            return ["ok": true, "size": settings.fontSize]
        case "/zoom":
            toggleMaximize()
            return ["ok": true]
        case "/read":
            guard let deskID = keyDeskID, let focused = desks[deskID]?.focusedID, let text = panes[focused]?.screenText() else {
                return ["ok": false, "error": "No terminal is focused."]
            }
            return ["ok": true, "pane": focused, "text": text]
        case "/view":
            let rows = desks.values.flatMap { desk in
                desk.layout.panes.map { id in
                    ["id": id, "desk": desk.id, "focused": desk.focusedID == id, "title": desk.panes[id]?.title ?? ""] as [String: Any]
                }
            }
            return ["ok": true, "panes": rows]
        default:
            return ["ok": false, "error": "Unknown request."]
        }
    }

    private func openAgentPane(zone: Zone?, command: String?, focus: Bool, share: Double?) -> String {
        let before = keyDeskID.flatMap { desks[$0]?.focusedID }
        if let zone {
            splitFocused(zone, command: command)
        } else {
            newPane(command: command)
        }
        let created = keyDeskID.flatMap { desks[$0]?.focusedID } ?? ""
        if let share, let deskID = keyDeskID {
            tuneShare(deskID: deskID, paneID: created, share: min(max(share, 0.1), 0.8))
        }
        if !focus, let before, let deskID = keyDeskID, var desk = desks[deskID] {
            desk.focusedID = before
            desks[deskID] = desk
            controllers[deskID]?.sync(animated: true)
        }
        return created
    }

    private func tuneShare(deskID: String, paneID: String, share: Double) {
        guard var desk = desks[deskID], let found = Self.splitHolding(paneID, desk.layout) else { return }
        let ratio = found.isA ? share : 1 - share
        desk.layout = Layout.setRatio(desk.layout, splitID: found.split, ratio: ratio)
        desks[deskID] = desk
        controllers[deskID]?.sync()
    }

    private static func splitHolding(_ paneID: String, _ node: LayoutNode) -> (split: String, isA: Bool)? {
        switch node {
        case .pane:
            return nil
        case .split(let id, _, _, let a, let b):
            if case .pane(let child) = a, child == paneID { return (id, true) }
            if case .pane(let child) = b, child == paneID { return (id, false) }
            return splitHolding(paneID, a) ?? splitHolding(paneID, b)
        }
    }

    private func share(_ raw: Any?) -> Double? {
        let number: Double?
        if let value = raw as? Double { number = value }
        else if let value = raw as? Int { number = Double(value) }
        else { number = nil }
        guard let number else { return nil }
        return number > 1 ? number / 100 : number
    }

    private func bool(_ raw: Any?, _ fallback: Bool) -> Bool {
        raw as? Bool ?? fallback
    }
}
