import AppKit
import Foundation
import Testing
@testable import AetherKit

private func actionRows() -> [PaletteRow] {
    AppAction.allCases.filter(\.inLauncher).map {
        PaletteRow(title: $0.title, detail: "", kind: .action(.app($0)), keywords: $0.keywords)
    }
}

private func launch(_ query: String, recents: [String] = [], hosts: [String] = []) -> [PaletteRow] {
    Launcher.rows(
        query: query,
        actions: actionRows(),
        tools: [(name: "git", path: "/usr/bin/git"), (name: "btop", path: "/opt/homebrew/bin/btop")],
        recents: recents,
        hosts: hosts
    )
}

@Test func launcherOpensAnActionItsQueryNames() {
    #expect(launch("settings").first?.kind == .action(.app(.settings)))
    #expect(launch("split").first?.section == .actions)
    #expect(launch("preferences").first?.kind == .action(.app(.settings)))
}

@Test func launcherRunsSomethingThatLooksLikeACommand() {
    #expect(launch("git status").first?.kind == .command("git status", newWindow: false))
    #expect(launch("ls").first?.kind == .command("ls", newWindow: false))
    #expect(launch("./build.sh").first?.kind == .command("./build.sh", newWindow: false))
    #expect(launch("btop").first?.kind == .command("btop", newWindow: false))
}

@Test func launcherOpensAnActionTypedInFull() {
    #expect(launch("split right").first?.kind == .action(.app(.splitRight)))
}

@Test func launcherShowsRecentsAndHosts() {
    let empty = launch("", recents: ["make test"], hosts: ["devbox"])
    #expect(empty.first?.title == "make test")
    #expect(empty.first?.section == .recent)
    #expect(empty.contains { $0.kind == .command("ssh devbox", newWindow: false) })
    let typed = launch("make", recents: ["make test", "npm start"])
    #expect(typed.first?.section == .run)
    #expect(typed.contains { $0.section == .recent && $0.title == "make test" })
    #expect(!typed.contains { $0.title == "npm start" })
}

@Test @MainActor func launcherSectionsGetOneHeaderEach() {
    let items = CommandPalette.items(for: launch("settings"))
    let headers = items.compactMap { item -> String? in
        if case .header(let title) = item { return title }
        return nil
    }
    #expect(headers.first == "Actions")
    #expect(Set(headers).count == headers.count)
}

@Test func recentsKeepTheNewestTwentyWithoutRepeats() {
    var list: [String] = []
    for index in 0..<25 { list = LauncherRecents.adding("cmd \(index)", to: list) }
    list = LauncherRecents.adding("cmd 10", to: list)
    #expect(list.count == 20)
    #expect(list.first == "cmd 10")
    #expect(list.filter { $0 == "cmd 10" }.count == 1)
}

@Test func sshConfigListsConcreteHosts() {
    let config = """
    # Personal
    Host devbox
        HostName 10.0.0.2
    Host *.internal bastion !blocked
    host=staging
    Host prod-?
    Host devbox # again
    Match host foo
    """
    #expect(SSHConfig.hosts(in: config) == ["devbox", "bastion", "staging"])
}

@Test func defaultShortcutsNeverCollide() {
    var seen: [String: AppAction] = [:]
    for action in AppAction.allCases {
        let chord = action.defaultChord
        guard !chord.key.isEmpty else { continue }
        let id = "\(chord.modifiers)-\(chord.key)"
        #expect(seen[id] == nil, "\(action) and \(seen[id]?.rawValue ?? "") share a shortcut")
        seen[id] = action
    }
    for reserved in AppAction.reservedChords {
        #expect(seen["\(reserved.modifiers)-\(reserved.key)"] == nil, "\(reserved.symbol) is taken by a standard menu item")
    }
}

@Test func paneNumbersRoundTrip() {
    for number in 1...9 {
        #expect(AppAction.focusPane(number)?.paneNumber == number)
        #expect(AppAction.focusPane(number)?.defaultChord.key == "\(number)")
    }
}

@Test func headerCaptionSplitsTitleFromPath() {
    let parts = PaneHeader.split(caption: "zsh   ~/proj")
    #expect(parts.title == "zsh")
    #expect(parts.path == "~/proj")
    #expect(PaneHeader.split(caption: "~/proj").title.isEmpty)
}

@Test func paneStateDecodesWithoutACustomTitle() throws {
    let json = #"{"id":"a","cwd":"/tmp","title":"zsh"}"#
    let state = try JSONDecoder().decode(PaneState.self, from: Data(json.utf8))
    #expect(state.customTitle == nil)
    var named = state
    named.customTitle = "server"
    let again = try JSONDecoder().decode(PaneState.self, from: JSONEncoder().encode(named))
    #expect(again.customTitle == "server")
}
