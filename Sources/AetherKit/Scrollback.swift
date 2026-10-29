import Foundation
import SwiftTerm

/// Each pane's screen and scrollback, kept as ANSI text in the support folder so it comes back
/// after a restart. The new shell starts below the old text, under a dim divider.
enum Scrollback {
    static let maxLines = 5_000
    static let maxBytes = 3 * 1024 * 1024

    /// Writes happen here, in order, off the main thread.
    private static let queue = DispatchQueue(label: "aether.scrollback", qos: .utility)

    static func directory() -> URL {
        System.supportDirectory().appendingPathComponent("scrollback", isDirectory: true)
    }

    static func fileURL(_ paneID: String) -> URL {
        directory().appendingPathComponent("\(paneID).ansi")
    }

    /// The normal screen and its scrollback as text with SGR colors, ending above the line the cursor
    /// is on, since the new shell draws its own prompt there. Nil while a full-screen program
    /// owns the screen, so the copy from before it started is kept.
    static func ansi(_ term: Terminal, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> String? {
        guard !term.isCurrentBufferAlternate else { return nil }
        let top = term.buffer.totalLinesTrimmed
        var lines: [BufferLine] = []
        while let line = term.getScrollInvariantLine(row: top + lines.count) {
            lines.append(line)
        }
        let cursorRow = lines.count - term.rows + term.buffer.y
        var end = min(max(cursorRow, 0), lines.count)
        // Blank lines and the rest of a multi-line prompt just above the cursor carry nothing worth restoring.
        while end > 0, lines[end - 1].translateToString(trimRight: true).isEmpty || isPrompt(lines[end - 1]) { end -= 1 }
        var start = max(0, end - maxLines)
        // Start on a line of its own, not halfway through a wrapped one, and not on blank lines.
        while start > 0, start < end, lines[start].isWrapped { start += 1 }
        while start < end, lines[start].translateToString(trimRight: true).isEmpty { start += 1 }
        var rows: [String] = []
        for index in start..<end {
            let wrapsOn = index + 1 < end && lines[index + 1].isWrapped
            var row = encode(lines[index], term: term, trim: !wrapsOn)
            if !wrapsOn { row += "\r\n" }
            rows.append(row)
        }
        // Over the byte cap, the oldest lines go first.
        var total = rows.reduce(0) { $0 + $1.utf8.count }
        var first = 0
        while total > maxBytes, first < rows.count {
            total -= rows[first].utf8.count
            first += 1
        }
        return rows[first...].joined()
    }

    private static func encode(_ line: BufferLine, term: Terminal, trim: Bool) -> String {
        var cells: [CharData] = []
        for col in 0..<line.count { cells.append(line[col]) }
        if trim {
            while let last = cells.last, " \0".contains(term.getCharacter(for: last)), isPlain(last.attribute) {
                cells.removeLast()
            }
        }
        var out = ""
        // Nil while the text is plain, so default cells need no codes at all.
        var current: Attribute?
        for cell in cells where cell.width != 0 {
            let attr: Attribute? = isPlain(cell.attribute) ? nil : cell.attribute
            if attr != current {
                out += attr.map(sgr) ?? "\u{1b}[0m"
                current = attr
            }
            let char = term.getCharacter(for: cell)
            out.append(char == "\0" ? " " : char)
        }
        if current != nil { out += "\u{1b}[0m" }
        return out
    }

    /// Marked as prompt by shell integration (OSC 133), from its first cell.
    private static func isPrompt(_ line: BufferLine) -> Bool {
        guard line.count > 0, case .prompt = line[0].semanticContent else { return false }
        return true
    }

    private static func isDefault(_ color: Attribute.Color) -> Bool {
        color == .defaultColor || color == .defaultInvertedColor
    }

    static func isPlain(_ attr: Attribute) -> Bool {
        attr.style.isEmpty && isDefault(attr.fg) && isDefault(attr.bg)
    }

    static func sgr(_ attr: Attribute) -> String {
        var codes = ["0"]
        let style = attr.style
        let flags: [(CharacterStyle, String)] = [
            (.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"), (.blink, "5"),
            (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9"),
        ]
        for (flag, code) in flags where style.contains(flag) { codes.append(code) }
        codes += color(attr.fg, base: 30, bright: 90, extended: 38)
        codes += color(attr.bg, base: 40, bright: 100, extended: 48)
        return "\u{1b}[\(codes.joined(separator: ";"))m"
    }

    private static func color(_ color: Attribute.Color, base: Int, bright: Int, extended: Int) -> [String] {
        switch color {
        case .ansi256(let code) where code < 8: return ["\(base + Int(code))"]
        case .ansi256(let code) where code < 16: return ["\(bright + Int(code) - 8)"]
        case .ansi256(let code): return ["\(extended)", "5", "\(code)"]
        case .trueColor(let r, let g, let b): return ["\(extended)", "2", "\(r)", "\(g)", "\(b)"]
        case .defaultColor, .defaultInvertedColor: return []
        }
    }

    /// The dim line between the old text and the new shell.
    static func divider(_ date: Date, cols: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        formatter.timeStyle = .short
        let label = " restored from \(formatter.string(from: date)) "
        let side = max(2, (min(cols, 100) - label.count) / 2)
        let rule = String(repeating: "─", count: side)
        return "\u{1b}[0;2m\(rule)\(label)\(rule)\u{1b}[0m\r\n"
    }

    /// Writes each pane's text, then deletes the files of every pane not in `keep`.
    /// `wait` blocks until done, for quitting.
    static func save(_ texts: [String: String], keep: Set<String>, wait: Bool = false) {
        let work: @Sendable () -> Void = {
            let dir = directory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (id, text) in texts {
                let url = fileURL(id)
                if text.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                // Created owner-only before any text lands in it.
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                try? Data(text.utf8).write(to: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "ansi" && !keep.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Forgets one pane's saved copy, for ⌘K.
    static func forget(_ paneID: String) {
        queue.async { try? FileManager.default.removeItem(at: fileURL(paneID)) }
    }

    /// The saved text and when it was written, or nil.
    static func load(_ paneID: String) -> (text: String, date: Date)? {
        queue.sync {
            let url = fileURL(paneID)
            guard let data = try? Data(contentsOf: url), !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            return (text, date)
        }
    }
}
