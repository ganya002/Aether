import Foundation
import SwiftTerm
import Testing
@testable import AetherKit

private let files: Set<String> = [
    "/proj/Sources/AetherKit/Layout.swift",
    "/proj/file.swift",
    "/proj/My Notes/todo list.txt",
    "/proj/report(1).pdf",
    "/Users/me/notes.md",
    "/proj/Sources",
]

/// The path found when the pointer is on the first character of `target` in `line`.
private func hit(_ line: String, on target: String) -> PathOpener.Hit? {
    let chars = Array(line)
    let index = line.distance(from: line.startIndex, to: line.range(of: target)!.lowerBound)
    return PathOpener.hit(in: chars, at: index, cwd: "/proj") { files.contains($0) }
}

@Test func pathsKeepLineAndColumn() {
    let found = hit("Sources/AetherKit/Layout.swift:42:7: error: nope", on: "Layout")
    #expect(found?.path == "/proj/Sources/AetherKit/Layout.swift")
    #expect(found?.line == 42)
    #expect(found?.column == 7)
    #expect(found?.link == "/proj/Sources/AetherKit/Layout.swift:42:7")
    #expect(found?.range == 0..<35)
}

@Test func grepOutputKeepsOnlyPathAndLine() {
    let found = hit("file.swift:12:    func run() {", on: "file")
    #expect(found?.path == "/proj/file.swift")
    #expect(found?.line == 12)
    #expect(found?.column == nil)
    let glued = hit("file.swift:12:func run()", on: "file")
    #expect(glued?.line == 12)
}

@Test func pathsLoseWrappingPunctuation() {
    #expect(hit("see (file.swift) here", on: "file")?.path == "/proj/file.swift")
    #expect(hit("see (file.swift:3), here", on: "file")?.line == 3)
    #expect(hit("at file.swift:12: warning", on: "file")?.range == 3..<16)
    #expect(hit("open \"file.swift\".", on: "file")?.path == "/proj/file.swift")
    #expect(hit("`file.swift`", on: "file")?.path == "/proj/file.swift")
    #expect(hit("got report(1).pdf.", on: "report")?.path == "/proj/report(1).pdf")
}

@Test func pathsWithSpacesAndHome() {
    #expect(hit("cat 'My Notes/todo list.txt'", on: "todo")?.path == "/proj/My Notes/todo list.txt")
    #expect(hit("wrote My Notes/todo list.txt ok", on: "Notes")?.path == "/proj/My Notes/todo list.txt")
    let home = (("~/notes.md" as NSString).expandingTildeInPath)
    #expect(PathOpener.absolute("~/notes.md", cwd: "/proj") == home)
    #expect(hit("./file.swift", on: "./")?.path == "/proj/file.swift")
    #expect(hit("../proj/Sources", on: "..")?.path == "/proj/Sources")
}

@Test func urlsAndMissingFilesAreNotPaths() {
    #expect(hit("see https://example.com/file.swift", on: "https") == nil)
    #expect(hit("see https://example.com/file.swift", on: "file") == nil)
    #expect(hit("missing.swift:3", on: "missing") == nil)
    #expect(hit("a b", on: " ") == nil)
}

@Test func parsesLineSuffixes() {
    #expect(PathOpener.parse("a.swift").line == nil)
    #expect(PathOpener.parse("a.swift:9").line == 9)
    #expect(PathOpener.parse("a.swift:9:4").column == 4)
    #expect(PathOpener.parse("a.swift:9:4:msg").path == "a.swift")
}

@Test func editorsJumpToTheLine() {
    #expect(PathOpener.editorArguments(tool: "code", path: "/a.swift", line: 3, column: 2) == ["-g", "/a.swift:3:2"])
    #expect(PathOpener.editorArguments(tool: "/usr/local/bin/cursor", path: "/a.swift", line: 3, column: nil) == ["-g", "/a.swift:3"])
    #expect(PathOpener.editorArguments(tool: "zed", path: "/a.swift", line: 3, column: nil) == ["/a.swift:3"])
    #expect(PathOpener.editorArguments(tool: "subl", path: "/a.swift", line: nil, column: nil) == ["/a.swift"])
    #expect(PathOpener.editorArguments(tool: "code --wait", path: "/a.swift", line: nil, column: nil) == ["/a.swift"])
    #expect(PathOpener.editorArguments(tool: "nvim", path: "/a.swift", line: 3, column: nil) == nil)
}

@Test func copyModeWordMotions() {
    let rows = ["let x = foo.bar(1)", "", "  next line"]
    let motion = CopyMotion(line: { Array(rows[$0]) }, lastRow: rows.count - 1)
    #expect(motion.nextWord(Position(col: 0, row: 0)) == Position(col: 4, row: 0))
    #expect(motion.nextWord(Position(col: 8, row: 0)) == Position(col: 11, row: 0))
    #expect(motion.nextWord(Position(col: 17, row: 0)) == Position(col: 2, row: 2))
    #expect(motion.endOfWord(Position(col: 8, row: 0)) == Position(col: 10, row: 0))
    #expect(motion.endOfWord(Position(col: 10, row: 0)) == Position(col: 11, row: 0))
    #expect(motion.previousWord(Position(col: 2, row: 2)) == Position(col: 17, row: 0))
    #expect(motion.previousWord(Position(col: 12, row: 0)) == Position(col: 11, row: 0))
    #expect(motion.endOfLine(0) == 17)
}

@Test func copyModeSearchWraps() {
    let rows = ["alpha Beta", "gamma beta", "delta"]
    let motion = CopyMotion(line: { Array(rows[$0]) }, lastRow: rows.count - 1)
    #expect(motion.find("beta", from: Position(col: 0, row: 0), forward: true) == Position(col: 6, row: 0))
    #expect(motion.find("beta", from: Position(col: 6, row: 0), forward: true) == Position(col: 6, row: 1))
    #expect(motion.find("beta", from: Position(col: 6, row: 1), forward: true) == Position(col: 6, row: 0))
    #expect(motion.find("Beta", from: Position(col: 6, row: 0), forward: true) == Position(col: 6, row: 0))
    #expect(motion.find("beta", from: Position(col: 0, row: 0), forward: false) == Position(col: 6, row: 1))
    #expect(motion.find("zeta", from: Position(col: 0, row: 0), forward: true) == nil)
}
