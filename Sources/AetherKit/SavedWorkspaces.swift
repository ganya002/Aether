import AppKit
import Foundation

/// A window's tab groups saved under a name: each tab's layout, and where each pane was and what it ran.
/// "Open Workspace: school" brings them all back at once.
struct SavedWorkspace: Codable, Equatable {
    struct Pane: Codable, Equatable {
        var id: String
        var cwd: String
        var command: String?
        var title: String?
    }

    struct Tab: Codable, Equatable {
        var name: String?
        var layout: LayoutNode
        var kind: LayoutKind
        var focusedID: String
        var panes: [Pane]
    }

    var name: String
    var saved: Date
    var tabs: [Tab]

    /// The window as it is now. `commands` holds what each pane is running, by pane id.
    static func capture(name: String, desk: Desk, commands: [String: String]) -> SavedWorkspace {
        let tabs = desk.tabs.map { tab in
            Tab(
                name: tab.name,
                layout: tab.layout,
                kind: tab.kind,
                focusedID: tab.focusedID,
                panes: Layout.visualIDs(tab.layout).compactMap { id in
                    desk.panes[id].map { Pane(id: id, cwd: $0.cwd, command: commands[id], title: $0.customTitle) }
                }
            )
        }
        return SavedWorkspace(name: name, saved: Date(), tabs: tabs)
    }

    /// Fresh tabs and panes to open, with new ids so the same workspace can be open twice.
    @MainActor func instantiate() -> (tabs: [WorkspaceTab], panes: [PaneState]) {
        var tabs: [WorkspaceTab] = []
        var states: [PaneState] = []
        for tab in self.tabs where !tab.panes.isEmpty {
            var ids: [String: String] = [:]
            for pane in tab.panes {
                let id = UUID().uuidString
                ids[pane.id] = id
                let command = pane.command?.trimmingCharacters(in: .whitespacesAndNewlines)
                let run = command?.isEmpty == false ? command : nil
                let folder = URL(fileURLWithPath: pane.cwd).lastPathComponent
                states.append(PaneState(
                    id: id, cwd: pane.cwd, command: run,
                    title: run?.split(separator: " ").first.map(String.init) ?? folder,
                    exitCode: nil, customTitle: pane.title
                ))
            }
            var layout = Self.renamed(tab.layout, ids)
            let known = Set(ids.values)
            if !Set(layout.panes).isSubset(of: known) || layout.panes.count != known.count {
                layout = AppModel.layout(for: tab.panes.compactMap { ids[$0.id] }, kind: tab.kind)
            }
            let focused = ids[tab.focusedID] ?? layout.panes[0]
            tabs.append(WorkspaceTab(id: UUID().uuidString, name: tab.name, layout: layout, kind: tab.kind, focusedID: focused, maximizedID: nil))
        }
        return (tabs, states)
    }

    private static func renamed(_ node: LayoutNode, _ ids: [String: String]) -> LayoutNode {
        switch node {
        case .pane(let id):
            return .pane(ids[id] ?? id)
        case .split(let splitID, let axis, let ratio, let a, let b):
            return .split(id: splitID, axis: axis, ratio: ratio, a: renamed(a, ids), b: renamed(b, ids))
        }
    }
}

/// Saved workspaces, in workspaces.json in the support folder.
enum WorkspaceStore {
    static func fileURL() -> URL {
        System.supportDirectory().appendingPathComponent("workspaces.json")
    }

    static func load() -> [SavedWorkspace] {
        guard let data = try? Data(contentsOf: fileURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedWorkspace].self, from: data)) ?? []
    }

    static func save(_ all: [SavedWorkspace]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) else { return }
        try? data.write(to: fileURL(), options: .atomic)
    }

    /// Names match without regard to case or surrounding spaces.
    static func find(_ name: String, in all: [SavedWorkspace]) -> Int? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.firstIndex { $0.name.compare(key, options: .caseInsensitive) == .orderedSame }
    }

    /// Saves `workspace`, replacing one with the same name.
    static func put(_ workspace: SavedWorkspace) {
        var all = load()
        if let index = find(workspace.name, in: all) { all[index] = workspace } else { all.append(workspace) }
        save(all)
    }

    @discardableResult
    static func rename(_ name: String, to newName: String) -> Bool {
        var all = load()
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = find(name, in: all), !trimmed.isEmpty else { return false }
        if let other = find(trimmed, in: all), other != index { return false }
        all[index].name = trimmed
        save(all)
        return true
    }

    @discardableResult
    static func delete(_ name: String) -> Bool {
        var all = load()
        guard let index = find(name, in: all) else { return false }
        all.remove(at: index)
        save(all)
        return true
    }
}

extension AppModel {
    /// What each pane in the window is running, for saving. A shell at its prompt has nothing.
    private func runningCommands(in desk: Desk) -> [String: String] {
        var commands: [String: String] = [:]
        for id in desk.allPaneIDs {
            guard let pane = panes[id], pane.chrome.terminal.remoteSession == nil else { continue }
            if let line = pane.currentCommand ?? desk.panes[id]?.command ?? pane.runningCommand()?.line {
                commands[id] = line
            }
        }
        return commands
    }

    /// Saves the window's tab groups under `name`. Nil when there is no window to save.
    @discardableResult
    func saveWorkspace(_ name: String, deskID: String? = nil) -> SavedWorkspace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = deskID ?? keyDeskID, let desk = desks[id], !desk.dropdown else { return nil }
        let workspace = SavedWorkspace.capture(name: trimmed, desk: desk, commands: runningCommands(in: desk))
        WorkspaceStore.put(workspace)
        return workspace
    }

    /// Opens a saved workspace in a new window, or in this one when it only holds an idle terminal.
    /// Returns the window it opened in.
    @discardableResult
    func openWorkspace(_ name: String) -> String? {
        let all = WorkspaceStore.load()
        guard let index = WorkspaceStore.find(name, in: all) else { return nil }
        let (tabs, states) = all[index].instantiate()
        guard !tabs.isEmpty else { return nil }
        if let deskID = keyDeskID, let desk = desks[deskID], !desk.dropdown, desk.tabs.count == 1,
           desk.allPaneIDs.count == 1, let only = panes[desk.focusedID], only.runningCommand() == nil,
           only.chrome.terminal.remoteSession == nil {
            let old = desk.tabs[0].id
            let opened = openTabs(tabs, panes: states, in: deskID)
            closeTab(old, in: deskID, confirm: false)
            return opened
        }
        return openTabs(tabs, panes: states, in: nil)
    }

    /// Asks for a name and saves the key window as a workspace.
    func promptSaveWorkspace() {
        guard let deskID = keyDeskID, desks[deskID]?.dropdown == false else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "school"
        field.setAccessibilityLabel("Workspace name")
        askName("Save Workspace", "Its tabs, layouts, folders, and running commands. A workspace with the same name is replaced.", button: "Save", field: field, deskID: deskID) { [weak self] name in
            guard let self, let saved = self.saveWorkspace(name, deskID: deskID) else { return }
            self.controllers[deskID]?.flashLayout("Saved “\(saved.name)”")
        }
    }

    func promptRenameWorkspace(_ name: String) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        field.setAccessibilityLabel("Workspace name")
        askName("Rename Workspace", "", button: "Rename", field: field, deskID: keyDeskID) { newName in
            if !WorkspaceStore.rename(name, to: newName) { NSSound.beep() }
        }
    }

    func confirmDeleteWorkspace(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "The workspace is forgotten. Open windows stay as they are."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { WorkspaceStore.delete(name) }
        }
        if let window = keyWindowForSheets, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func askName(_ title: String, _ detail: String, button: String, field: NSTextField, deskID: String?, then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !name.isEmpty { then(name) }
        }
        if let window = deskID.flatMap({ controllers[$0]?.window }), window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Rows for `aether workspaces`.
    static func workspaceRows(_ all: [SavedWorkspace]) -> [[String: Any]] {
        all.map { workspace in
            [
                "name": workspace.name,
                "saved": ISO8601DateFormatter().string(from: workspace.saved),
                "tabs": workspace.tabs.map { tab -> [String: Any] in
                    [
                        "name": tab.name ?? "",
                        "kind": tab.kind.rawValue,
                        "panes": tab.panes.map { ["cwd": $0.cwd, "command": $0.command ?? ""] },
                    ]
                },
            ]
        }
    }
}
