import AppKit
import Carbon.HIToolbox
import Foundation
import Quartz
import SwiftTerm

/// Where ⌘-clicked files open. Automatic follows $VISUAL or $EDITOR when it names a GUI editor, then the file's default app.
public enum EditorChoice: String, Codable, CaseIterable, Sendable {
    case automatic
    case vsCode
    case cursor
    case zed
    case sublime
    case defaultApp

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .vsCode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .sublime: "Sublime Text"
        case .defaultApp: "The file's default app"
        }
    }

    /// The command line tool, and where it sits inside the app when it is not on PATH.
    var tool: (name: String, bundleID: String, inApp: String)? {
        switch self {
        case .vsCode: ("code", "com.microsoft.VSCode", "Contents/Resources/app/bin/code")
        case .cursor: ("cursor", "com.todesktop.230313mzl4w4u92", "Contents/Resources/app/bin/cursor")
        case .zed: ("zed", "dev.zed.Zed", "Contents/MacOS/cli")
        case .sublime: ("subl", "com.sublimetext.4", "Contents/SharedSupport/bin/subl")
        case .automatic, .defaultApp: nil
        }
    }
}

enum PathOpener {
    struct LocatedFile {
        var url: URL
        var line: Int?
        var column: Int?
    }

    /// A file path found in a row of terminal text. `range` is in characters of that row.
    struct Hit: Equatable {
        var path: String
        var line: Int?
        var column: Int?
        var range: Range<Int>

        /// "path:line:col", the form editors and `open(_:cwd:)` understand.
        var link: String {
            path + (line.map { ":\($0)" } ?? "") + (column.map { ":\($0)" } ?? "")
        }
    }

    // MARK: Finding paths in text

    private static let openers: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
    private static let trailing: Set<Character> = ["\"", "'", "`", ".", ",", ";", ":", "!", "?"]

    static func isURL(_ token: String) -> Bool {
        token.contains("://") || token.lowercased().hasPrefix("mailto:")
    }

    /// Spans around `index` that could be a path, best first: a quoted string, then runs of words
    /// joined by single spaces (for names with spaces), longest first, then the word alone.
    static func candidates(in chars: [Character], at index: Int) -> [Range<Int>] {
        guard chars.indices.contains(index), !chars[index].isWhitespace else { return [] }
        var spans: [Range<Int>] = []
        for quote in ["\"", "'", "`"] as [Character] {
            guard let open = chars[..<index].lastIndex(of: quote),
                  let close = chars[(index + 1)...].firstIndex(of: quote) else { continue }
            spans.append((open + 1)..<close)
        }
        var words: [Range<Int>] = []
        var start: Int?
        for (offset, character) in chars.enumerated() {
            if character.isWhitespace {
                if let first = start { words.append(first..<offset) }
                start = nil
            } else if start == nil {
                start = offset
            }
        }
        if let first = start { words.append(first..<chars.count) }
        guard let here = words.firstIndex(where: { $0.contains(index) }) else { return spans }
        // Only words one space apart join up. `ls` pads its columns with more than that.
        var low = here
        while low > here - 2, low > 0, words[low - 1].upperBound + 1 == words[low].lowerBound { low -= 1 }
        var high = here
        while high < here + 2, high < words.count - 1, words[high].upperBound + 1 == words[high + 1].lowerBound { high += 1 }
        var joined: [Range<Int>] = []
        for left in low...here {
            for right in here...high {
                joined.append(words[left].lowerBound..<words[right].upperBound)
            }
        }
        spans += joined.sorted { $0.count > $1.count }
        return spans
    }

    /// Drops wrapping punctuation: `(file.swift)`, `"file"`, `file.swift:12:`, `file.swift,`.
    /// Brackets that belong to the name, like `report(1).pdf`, stay.
    static func trim(_ chars: [Character], _ span: Range<Int>) -> Range<Int> {
        var low = span.lowerBound
        var high = span.upperBound
        func count(_ character: Character) -> Int { chars[low..<high].filter { $0 == character }.count }
        while low < high {
            let first = chars[low]
            let last = chars[high - 1]
            if high - low >= 2, closers[last] == first {
                low += 1
                high -= 1
            } else if trailing.contains(last) || (closers[last].map { count($0) < count(last) } ?? false) {
                high -= 1
            } else if openers.contains(first), closers.first(where: { $0.value == first }).map({ count($0.key) < count(first) }) ?? true {
                low += 1
            } else {
                break
            }
        }
        return low..<high
    }

    /// Splits `file.swift:12:7` into the path and its line and column. Grep's `file:12:text` keeps only the path and line.
    static func parse(_ token: String) -> (path: String, line: Int?, column: Int?) {
        guard let match = token.firstMatch(of: /^(.+?):(\d+)(?::(\d+))?(?::.*)?$/) else { return (token, nil, nil) }
        return (String(match.1), Int(match.2), match.3.flatMap { Int($0) })
    }

    /// The absolute path a token names, with `~` expanded and relative paths taken from `cwd`.
    static func absolute(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return (full as NSString).standardizingPath
    }

    /// The first span around `index` that names a file or folder that exists. URLs are never paths.
    static func hit(in chars: [Character], at index: Int, cwd: String,
                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Hit? {
        for span in candidates(in: chars, at: index) {
            let range = trim(chars, span)
            guard !range.isEmpty else { continue }
            let token = String(chars[range])
            if isURL(token) { return nil }
            for (path, line, column) in [(token, nil, nil), parse(token)] where !path.isEmpty {
                // Grep's `file:12:text` underlines only `file:12`.
                let length = path.count + (line.map { ":\($0)".count } ?? 0) + (column.map { ":\($0)".count } ?? 0)
                let found = range.lowerBound..<(range.lowerBound + length)
                guard found.contains(index) else { continue }
                let full = absolute(path, cwd: cwd)
                if exists(full) { return Hit(path: full, line: line, column: column, range: found) }
            }
        }
        return nil
    }

    // MARK: Opening

    /// Resolves a command-clicked token against the pane's working directory.
    static func locate(_ raw: String, cwd: String) -> LocatedFile? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: token), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return LocatedFile(url: url)
        }
        let chars = Array(token)
        guard !chars.isEmpty else { return nil }
        let range = trim(chars, 0..<chars.count)
        guard !range.isEmpty else { return nil }
        let text = String(chars[range])
        for (path, line, column) in [(text, nil, nil), parse(text)] {
            let full = absolute(path, cwd: cwd)
            if FileManager.default.fileExists(atPath: full) {
                return LocatedFile(url: URL(fileURLWithPath: full), line: line, column: column)
            }
        }
        return nil
    }

    @discardableResult
    @MainActor
    static func open(_ raw: String, cwd: String) -> Bool {
        guard let target = locate(raw, cwd: cwd) else { return false }
        guard target.url.isFileURL else { return NSWorkspace.shared.open(target.url) }
        let choice = AppModel.shared.settings.editor
        if choice == .automatic {
            Task.detached {
                let command = Self.preferredEditor()
                await MainActor.run { _ = Self.launch(target, command: command, choice: .automatic) }
            }
            return true
        }
        return launch(target, command: nil, choice: choice)
    }

    @MainActor
    private static func launch(_ target: LocatedFile, command: String?, choice: EditorChoice) -> Bool {
        let path = target.url.path
        if let command, let arguments = editorArguments(tool: command, path: path, line: target.line, column: target.column),
           let tool = command.hasPrefix("/") ? command : System.executable(named: command),
           run(tool, arguments) {
            return true
        }
        if let info = choice.tool {
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: info.bundleID)
            let tool = System.executable(named: info.name) ?? app.map { $0.appendingPathComponent(info.inApp).path }
            if let tool, FileManager.default.isExecutableFile(atPath: tool),
               let arguments = editorArguments(tool: info.name, path: path, line: target.line, column: target.column),
               run(tool, arguments) {
                return true
            }
            if let app {
                NSWorkspace.shared.open([target.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
        }
        return NSWorkspace.shared.open(target.url)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    /// How a GUI editor's command line opens a file at a line. Nil for terminal editors and anything unknown.
    static func editorArguments(tool: String, path: String, line: Int?, column: Int?) -> [String]? {
        let name = URL(fileURLWithPath: tool.split(separator: " ").first.map(String.init) ?? tool).lastPathComponent
        let spot = path + (line.map { ":\($0)" + (column.map { ":\($0)" } ?? "") } ?? "")
        switch name {
        case "code", "code-insiders", "cursor", "codium", "windsurf":
            return line == nil ? [path] : ["-g", spot]
        case "zed", "cli", "subl":
            return [spot]
        case "mate", "xed":
            return line.map { ["-l", "\($0)", path] } ?? [path]
        case "bbedit":
            return line.map { ["+\($0)", path] } ?? [path]
        default:
            return nil
        }
    }

    /// $VISUAL, then $EDITOR. An app opened from the Dock does not have the shell's variables, so the login shell is asked once.
    nonisolated(unsafe) private static var shellEditor: String?
    private static let shellEditorLock = NSLock()

    static func preferredEditor() -> String? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["VISUAL", "EDITOR"] {
            if let value = environment[key], !value.isEmpty { return value.split(separator: " ").first.map(String.init) }
        }
        shellEditorLock.lock()
        defer { shellEditorLock.unlock() }
        if let shellEditor { return shellEditor.isEmpty ? nil : shellEditor }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: System.userShell())
        process.arguments = ["-ilc", "printf '\\n<aether>%s</aether>' \"${VISUAL:-$EDITOR}\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var found = ""
        if (try? process.run()) != nil {
            // ponytail: a slow shell startup past 3 s gives up and uses the default app until relaunch.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            let text = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            if let match = text.firstMatch(of: /<aether>([^<]*)<\/aether>/) {
                found = match.1.split(separator: " ").first.map(String.init) ?? ""
            }
        }
        shellEditor = found
        return found.isEmpty ? nil : found
    }
}

/// What the pointer last found with ⌘ held, and what Quick Look is showing.
struct PathPeek {
    var hovered: (path: String, at: Date)?
    var previewing: URL?
}

extension AetherTerminal: @preconcurrency QLPreviewPanelDataSource {
    /// One row of the buffer, one character per cell. The right half of a wide character repeats it.
    func cellText(row: Int) -> [Character] {
        guard let terminal, let line = terminal.bufferLine(atRow: row) else { return [] }
        var chars: [Character] = []
        for col in 0..<min(terminal.cols, line.count) {
            if col > 0, line[col - 1].width == 2 {
                chars.append(chars[col - 1])
                continue
            }
            let character = terminal.getCharacter(for: line[col])
            chars.append(character == "\u{0}" ? " " : character)
        }
        return chars
    }

    /// Lets SwiftTerm underline and click file paths that exist, as it does links. Called with ⌘ held.
    func installPathLinks() {
        terminal.hostLinkMatcher = { [weak self] position in
            MainActor.assumeIsolated {
                guard let self else { return .fallback }
                let chars = self.cellText(row: position.row)
                guard let hit = PathOpener.hit(in: chars, at: position.col, cwd: self.workingDirectory()) else {
                    return self.mightBeURL(chars, row: position.row, col: position.col) ? .fallback : .none
                }
                self.pathPeek.hovered = (hit.path, Date())
                return .link(text: hit.link, range: hit.range)
            }
        }
    }

    /// URLs, and the pieces of a URL that wrapped onto the next row, are left to SwiftTerm.
    private func mightBeURL(_ chars: [Character], row: Int, col: Int) -> Bool {
        guard let terminal else { return true }
        guard chars.indices.contains(col) else { return false }
        var low = col
        while low > 0, !chars[low - 1].isWhitespace { low -= 1 }
        var high = col
        while high < chars.count, !chars[high].isWhitespace { high += 1 }
        if PathOpener.isURL(String(chars[low..<min(high, chars.count)])) { return true }
        let wrappedIn = low == 0 && terminal.bufferLine(atRow: row)?.isWrapped == true
        let wrapsOut = high >= terminal.cols && terminal.bufferLine(atRow: row + 1)?.isWrapped == true
        return wrappedIn || wrapsOut
    }

    /// The buffer cell under a point in this view.
    func cell(at point: NSPoint) -> Position? {
        guard let terminal, caretFrame.width > 0, caretFrame.height > 0, bounds.contains(point) else { return nil }
        let col = min(terminal.cols - 1, Int(point.x / caretFrame.width))
        let row = Int((bounds.height - point.y) / caretFrame.height)
        guard row >= 0, row < terminal.rows else { return nil }
        return Position(col: col, row: row + terminal.getTopVisibleRow())
    }

    func pathHit(at point: NSPoint) -> PathOpener.Hit? {
        guard let cell = cell(at: point) else { return nil }
        return PathOpener.hit(in: cellText(row: cell.row), at: cell.col, cwd: workingDirectory())
    }

    private var pathUnderMouse: PathOpener.Hit? {
        guard let window else { return nil }
        return pathHit(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Space right after ⌘-hovering a path, or with ⌘ still down, previews it.
    func quickLookKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Space),
              event.modifierFlags.intersection([.shift, .control, .option]).isEmpty,
              let hovered = pathPeek.hovered else { return false }
        let fresh = event.modifierFlags.contains(.command) || Date().timeIntervalSince(hovered.at) < 3
        guard fresh, let hit = pathUnderMouse, hit.path == hovered.path else { return false }
        showQuickLook(hit.path)
        return true
    }

    func showQuickLook(_ path: String) {
        pathPeek.previewing = URL(fileURLWithPath: path)
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Force click on a path.
    override func quickLook(with event: NSEvent) {
        if let hit = pathHit(at: convert(event.locationInWindow, from: nil)) {
            showQuickLook(hit.path)
        } else {
            super.quickLook(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        pathPeek.previewing != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        pathPeek.previewing = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        pathPeek.previewing == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        pathPeek.previewing as NSURL?
    }

    /// Right-click on a path: Open, Reveal in Finder, Quick Look.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = pathHit(at: convert(event.locationInWindow, from: nil)) else { return super.menu(for: event) }
        let menu = NSMenu()
        // SwiftTerm's menu validation only knows its own actions.
        menu.autoenablesItems = false
        let name = (hit.path as NSString).lastPathComponent
        for (title, action) in [("Open “\(name)”", #selector(openPath(_:))),
                                ("Reveal in Finder", #selector(revealPath(_:))),
                                ("Quick Look", #selector(quickLookPath(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = hit.link
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openPath(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String { PathOpener.open(link, cwd: workingDirectory()) }
    }

    @objc private func revealPath(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String, let file = PathOpener.locate(link, cwd: workingDirectory()) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    @objc private func quickLookPath(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String, let file = PathOpener.locate(link, cwd: workingDirectory()) else { return }
        showQuickLook(file.url.path)
    }
}
