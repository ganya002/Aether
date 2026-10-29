import AppKit
import Foundation
import Testing
@testable import AetherKit

@Test func deskWithoutSavedTabsBecomesOneTab() {
    let pane = PaneState(id: "a", cwd: "/tmp", command: nil, title: "zsh", exitCode: nil)
    let desk = Desk(
        id: "d",
        layout: .pane("a"),
        kind: .tall,
        focusedID: "a",
        maximizedID: nil,
        broadcast: false,
        frame: .zero,
        panes: ["a": pane]
    )
    #expect(desk.tabs.count == 1)
    #expect(desk.layout == .pane("a"))
    #expect(desk.focusedID == "a")
    #expect(desk.allPaneIDs == ["a"])
}

@Test func deskKeepsSeparateLayoutsPerTab() {
    let a = PaneState(id: "a", cwd: "/tmp", command: nil, title: "school", exitCode: nil)
    let b = PaneState(id: "b", cwd: "/tmp", command: nil, title: "agent", exitCode: nil)
    var desk = Desk(
        id: "d",
        layout: .pane("a"),
        kind: .tall,
        focusedID: "a",
        maximizedID: nil,
        broadcast: false,
        frame: .zero,
        panes: ["a": a, "b": b],
        tabs: [
            WorkspaceTab(id: "t1", name: "School", layout: .pane("a"), kind: .tall, focusedID: "a", maximizedID: nil),
            WorkspaceTab(id: "t2", name: "Agent", layout: .pane("b"), kind: .rows, focusedID: "b", maximizedID: nil),
        ],
        activeTabID: "t2"
    )
    #expect(desk.activeTabID == "t2")
    #expect(desk.layout == .pane("b"))
    #expect(desk.kind == .rows)
    #expect(desk.focusedID == "b")
    #expect(Set(desk.allPaneIDs) == ["a", "b"])
    desk.layout = .pane("b")
    desk.focusedID = "b"
    #expect(desk.tabs[0].layout == .pane("a"))
    #expect(desk.tabs[1].focusedID == "b")
}

@Test func workspaceTabTitlePrefersAName() {
    let pane = PaneState(id: "a", cwd: "/tmp", command: nil, title: "zsh", exitCode: nil)
    let named = WorkspaceTab(id: "t", name: "School", layout: .pane("a"), kind: .tall, focusedID: "a", maximizedID: nil)
    let blank = WorkspaceTab(id: "t", name: "  ", layout: .pane("a"), kind: .tall, focusedID: "a", maximizedID: nil)
    #expect(named.title(from: ["a": pane]) == "School")
    #expect(blank.title(from: ["a": pane]) == "zsh")
}

@MainActor @Test func savedDeskDecodesWithoutTabs() throws {
    let pane = PaneState(id: "a", cwd: "/tmp", command: nil, title: "zsh", exitCode: nil)
    let saved = SavedDesk(
        id: "d",
        x: 0,
        y: 0,
        w: 800,
        h: 600,
        layout: .pane("a"),
        focusedID: "a",
        maximizedID: nil,
        kind: .tall,
        panes: [pane],
        tabs: nil,
        activeTabID: nil
    )
    let again = try JSONDecoder().decode(SavedDesk.self, from: JSONEncoder().encode(saved))
    #expect(again.tabs == nil)
    let tabs = AppModel.restoredTabs(again, panes: ["a": pane], layout: again.layout, focusedID: "a")
    #expect(tabs.count == 1)
    #expect(tabs[0].layout == .pane("a"))
    #expect(tabs[0].focusedID == "a")
}

@MainActor @Test func restoredTabsDropsEmptyGroupsAndRepairsFocus() {
    let pane = PaneState(id: "a", cwd: "/tmp", command: nil, title: "zsh", exitCode: nil)
    let saved = SavedDesk(
        id: "d",
        x: 0,
        y: 0,
        w: 800,
        h: 600,
        layout: .pane("a"),
        focusedID: "a",
        maximizedID: nil,
        kind: .tall,
        panes: [pane],
        tabs: [
            WorkspaceTab(id: "gone", name: nil, layout: .pane("missing"), kind: .tall, focusedID: "missing", maximizedID: nil),
            WorkspaceTab(id: "keep", name: "School", layout: .pane("a"), kind: .tall, focusedID: "missing", maximizedID: "missing"),
        ],
        activeTabID: "keep"
    )
    let tabs = AppModel.restoredTabs(saved, panes: ["a": pane], layout: saved.layout, focusedID: "a")
    #expect(tabs.map(\.id) == ["keep"])
    #expect(tabs[0].focusedID == "a")
    #expect(tabs[0].maximizedID == nil)
    #expect(tabs[0].name == "School")
}

@Test func agentSkillsMergeClaudeHooksOnce() throws {
    let command = AgentSkills.hookCommand()
    let first = try #require(AgentSkills.mergeClaudeSettings(Data("{}".utf8), command: command))
    let second = try #require(AgentSkills.mergeClaudeSettings(first, command: command))
    let json = try JSONSerialization.jsonObject(with: second) as? [String: Any]
    let session = ((json?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
    #expect(session.count == 1)
    let inner = (session.first?["hooks"] as? [[String: Any]]) ?? []
    #expect(inner.contains { ($0["command"] as? String)?.contains("aether") == true && ($0["command"] as? String)?.contains("hook") == true })
}

@Test func agentSkillsMergeCodexHooksOnce() throws {
    let command = AgentSkills.hookCommand()
    let first = try #require(AgentSkills.mergeCodexHooks(Data("{}".utf8), command: command))
    let second = try #require(AgentSkills.mergeCodexHooks(first, command: command))
    let json = try JSONSerialization.jsonObject(with: second) as? [String: Any]
    let session = ((json?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
    #expect(session.count == 1)
}

@Test func agentSkillsInstallsOnlyIntoHomesThatExist() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("aether-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let done = AgentSkills.install(
        skill: "# skill\n",
        agents: "# agents\n",
        home: home,
        env: [:],
        path: "/usr/bin"
    )
    #expect(done.contains("Claude Code"))
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/aether/SKILL.md").path))
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/skills/aether/SKILL.md").path))
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("AGENTS.md").path))
}

@Test func processIconMapsKnownTools() {
    #expect(ProcessIcon.bundleID("node") == "com.nodejs.nodejs")
    #expect(ProcessIcon.bundleID("claude") == "com.anthropic.claudefordesktop")
    #expect(ProcessIcon.bundleID("cursor") == "com.todesktop.230313mzl4w4u92")
    #expect(ProcessIcon.bundleID("bun") == "com.oven-sh.bun")
    #expect(ProcessIcon.bundleID("fish") == "com.ridiculousfish.fishapp")
    #expect(ProcessIcon.bundleID("zsh") == nil)
}

@Test func newTabShortcutIsShiftCommandT() {
    #expect(AppAction.newPane.defaultChord.key == "t")
    #expect(AppAction.newPane.defaultChord.modifiers == NSEvent.ModifierFlags.command.rawValue)
    #expect(AppAction.newTab.defaultChord.key == "t")
    #expect(AppAction.newTab.defaultChord.modifiers == (NSEvent.ModifierFlags.command.union(.shift)).rawValue)
    #expect(AppAction.nextTab.defaultChord.key == "\t")
    #expect(AppAction.nextTab.defaultChord.modifiers == NSEvent.ModifierFlags.control.rawValue)
}
