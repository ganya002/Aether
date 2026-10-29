import Foundation
import Testing
@testable import AetherKit

@Test func agentKeysEncodeControlAndNamedKeys() {
    #expect(AgentKeys.encode("ctrl+c") == [0x03])
    #expect(AgentKeys.encode("^c") == [0x03])
    #expect(AgentKeys.encode("c-c") == [0x03])
    #expect(AgentKeys.encode("enter") == [0x0d])
    #expect(AgentKeys.encode("ctrl+c,enter") == [0x03, 0x0d])
    #expect(AgentKeys.encode("up") == [0x1b, 0x5b, 0x41])
    #expect(AgentKeys.encode("tab") == [0x09])
    #expect(AgentKeys.encode("esc") == [0x1b])
    #expect(AgentKeys.encode("alt+x") == [0x1b, 0x78])
    #expect(AgentKeys.encode("not-a-key") == nil)
}

@Test func agentInputPrefersKeysOverText() {
    let keys = try? AgentInput.bytes(["keys": "ctrl+c", "text": "hello"]).get()
    #expect(keys == [0x03])
    let typed = try? AgentInput.bytes(["text": "yes", "enter": true]).get()
    #expect(typed == Array("yes".utf8) + [0x0d])
    #expect(AgentInput.bytes([:]) == .failure(AgentError("Give text or --keys.")))
}

@Test func paneIdsResolveByPrefix() {
    let desks = [
        "D1": desk("D1", ["AAAAAAAA-1111-1111-1111-111111111111", "BBBBBBBB-2222-2222-2222-222222222222"], focused: "AAAAAAAA-1111-1111-1111-111111111111"),
    ]
    let found = try? AgentArgs.resolvePane("AAAAAAAA", desks: desks).get()
    #expect(found == "AAAAAAAA-1111-1111-1111-111111111111")
    #expect(AgentArgs.resolvePane("gone", desks: desks) == .failure(AgentError("No pane gone.")))
}

@Test func aNamedWindowBecomesTheTarget() {
    let desks = [
        "D1": desk("D1", ["A", "B"], focused: "A"),
        "D2": desk("D2", ["C"], focused: "C"),
    ]
    let target = try? AgentArgs.target(pane: nil, session: nil, desks: desks, sessions: [:], keyDesk: "D1", window: "D2").get()
    #expect(target == AgentArgs.Target(desk: "D2", pane: "C", explicit: false))
}

@Test func oneWindowDoesNotNeedAPaneEnv() {
    let desks = ["D1": desk("D1", ["A"], focused: "A")]
    let target = try? AgentArgs.target(pane: nil, session: nil, desks: desks, sessions: [:], keyDesk: nil).get()
    #expect(target == AgentArgs.Target(desk: "D1", pane: "A", explicit: false))
}

@Test func severalWindowsNeedATarget() {
    let desks = [
        "D1": desk("D1", ["A"], focused: "A"),
        "D2": desk("D2", ["C"], focused: "C"),
    ]
    let result = AgentArgs.target(pane: nil, session: nil, desks: desks, sessions: [:], keyDesk: nil)
    #expect(result == .failure(AgentError("Pass --pane, --window, or --desk. Several windows are open.")))
}

@Test func layoutOrderAndMoveKeepEveryPane() {
    let tree = Layout.arrange(["a", "b", "c"], pattern: .columns)!
    let reversed = Layout.ordered(tree, as: ["c", "b", "a"])
    #expect(Layout.visualIDs(reversed) == ["c", "b", "a"])
    let moved = Layout.move(tree, id: "c", before: "a")
    #expect(Layout.visualIDs(moved).first == "c")
    let indexed = Layout.move(tree, id: "a", index: 2)
    #expect(Layout.visualIDs(indexed).last == "a")
}

private func desk(_ id: String, _ panes: [String], focused: String) -> Desk {
    var states: [String: PaneState] = [:]
    for pane in panes {
        states[pane] = PaneState(id: pane, cwd: "/tmp", command: nil, title: pane, exitCode: nil)
    }
    return Desk(id: id, layout: Layout.arrange(panes, pattern: .rows) ?? .pane(panes[0]), kind: .tall, focusedID: focused, maximizedID: nil, broadcast: false, frame: .zero, panes: states)
}
