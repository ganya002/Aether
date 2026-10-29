import Foundation
import Testing
@testable import AetherKit

private func schoolDesk() -> Desk {
    let tabs = [
        WorkspaceTab(id: "t1", name: "notes", layout: .pane("a"), kind: .tall, focusedID: "a", maximizedID: nil),
        WorkspaceTab(id: "t2", name: nil, layout: .split(id: "s", axis: .row, ratio: 0.3, a: .pane("b"), b: .pane("c")), kind: .splits, focusedID: "c", maximizedID: "c"),
    ]
    let panes = [
        "a": PaneState(id: "a", cwd: "/tmp/notes", command: nil, title: "zsh", exitCode: nil, customTitle: "Notes"),
        "b": PaneState(id: "b", cwd: "/tmp/site", command: nil, title: "zsh", exitCode: nil),
        "c": PaneState(id: "c", cwd: "/tmp/site", command: nil, title: "zsh", exitCode: nil),
    ]
    return Desk(id: "D", layout: .pane("a"), kind: .tall, focusedID: "a", maximizedID: nil, broadcast: false, frame: .zero, panes: panes, tabs: tabs)
}

@MainActor @Test func savedWorkspaceKeepsTabsLayoutsFoldersAndCommands() throws {
    let saved = SavedWorkspace.capture(name: "school", desk: schoolDesk(), commands: ["c": "npm run dev"])
    #expect(saved.tabs.map(\.name) == ["notes", nil])
    #expect(saved.tabs[1].panes.map(\.cwd) == ["/tmp/site", "/tmp/site"])
    #expect(saved.tabs[1].panes.map(\.command) == [nil, "npm run dev"])
    #expect(saved.tabs[0].panes[0].title == "Notes")

    // Round trips through JSON, as workspaces.json stores it.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(SavedWorkspace.self, from: encoder.encode(saved))
    #expect(back.tabs == saved.tabs)

    let (tabs, panes) = saved.instantiate()
    #expect(tabs.count == 2 && panes.count == 3)
    #expect(Set(panes.map(\.id)).isDisjoint(with: ["a", "b", "c"]))
    #expect(tabs[0].name == "notes")
    guard case .split(_, .row, 0.3, .pane(let left), .pane(let right)) = tabs[1].layout else {
        Issue.record("layout lost its split")
        return
    }
    #expect(tabs[1].focusedID == right)
    let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
    #expect(byID[left]?.command == nil)
    #expect(byID[right]?.command == "npm run dev")
    #expect(byID[right]?.title == "npm")
    #expect(byID[tabs[0].focusedID]?.customTitle == "Notes")
}

@Test func workspaceNamesMatchWithoutCase() {
    let all = [SavedWorkspace(name: "School", saved: Date(), tabs: [])]
    #expect(WorkspaceStore.find(" school ", in: all) == 0)
    #expect(WorkspaceStore.find("work", in: all) == nil)
}
