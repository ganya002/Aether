import Foundation
import SwiftTerm
import Testing
@testable import AetherKit

/// Kept alive, since a terminal does not own its delegate.
nonisolated(unsafe) private var hosts: [HeadlessTerminal] = []

private func terminal(cols: Int = 20, rows: Int = 5) -> Terminal {
    let host = HeadlessTerminal(options: TerminalOptions(cols: cols, rows: rows, scrollback: 100)) { _ in }
    hosts.append(host)
    return host.terminal
}

@Test func scrollbackKeepsColorsAndRoundTrips() {
    let term = terminal()
    term.feed(text: "plain\r\n\u{1b}[1;31mred\u{1b}[0m and \u{1b}[38;5;200mpink\u{1b}[0m\r\n\u{1b}[38;2;1;2;3mtrue\u{1b}[0m\r\n$ ")
    let text = Scrollback.ansi(term)!
    // The prompt line the cursor sits on is left for the new shell.
    #expect(!text.contains("$"))
    #expect(text.hasPrefix("plain\r\n"))
    #expect(text.contains("\u{1b}[0;1;31mred\u{1b}[0m and \u{1b}[0;38;5;200mpink\u{1b}[0m\r\n"))
    #expect(text.contains("\u{1b}[0;38;2;1;2;3mtrue"))

    let copy = terminal()
    copy.feed(text: text)
    #expect(Scrollback.ansi(copy) == text)
}

@Test func scrollbackJoinsWrappedLinesAndCapsLines() {
    let term = terminal(cols: 10)
    term.feed(text: String(repeating: "x", count: 25) + "\r\n")
    for n in 0..<30 { term.feed(text: "line \(n)\r\n") }
    let text = Scrollback.ansi(term, maxLines: 10)!
    let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    #expect(lines.count == 10)
    #expect(lines.last == "line 29")
    let wide = Scrollback.ansi(term)!
    #expect(wide.hasPrefix(String(repeating: "x", count: 25) + "\r\n"))
    let capped = Scrollback.ansi(term, maxBytes: 20)!
    #expect(capped.utf8.count <= 20)
    #expect(capped.hasSuffix("line 29\r\n"))
}

@Test func scrollbackLeavesTheLastPromptForTheNewShell() {
    let term = terminal()
    term.feed(text: "\u{1b}]133;A\u{07}~/code\r\n> \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}out\r\n\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}~/code\r\n> ")
    #expect(Scrollback.ansi(term) == "~/code\r\n> ls\r\nout\r\n")
}

@Test func scrollbackSkipsFullScreenPrograms() {
    let term = terminal()
    term.feed(text: "hello\r\n\u{1b}[?1049h")
    #expect(Scrollback.ansi(term) == nil)
}

@Test func restoreContentsDefaultsOn() throws {
    #expect(Settings().restoreContents)
    let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"restoreContents": false}"#.utf8))
    #expect(!off.restoreContents)
}
