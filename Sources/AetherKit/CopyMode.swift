import AppKit
import Carbon.HIToolbox
import SwiftTerm

/// Cursor motions for copy mode, on buffer rows. `line` gives a row's characters; trailing blanks do not count.
struct CopyMotion {
    var line: (Int) -> [Character]
    var lastRow: Int

    /// Blank, word character, or punctuation, as vi splits words.
    static func kind(_ character: Character) -> Int {
        if character.isWhitespace { return 0 }
        return character.isLetter || character.isNumber || character == "_" ? 1 : 2
    }

    private func text(_ row: Int) -> [Character] {
        var chars = line(row)
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        return chars
    }

    /// `w`: the start of the next word, across rows.
    func nextWord(_ from: Position) -> Position {
        var row = from.row
        var chars = text(row)
        var col = from.col
        let kind = col < chars.count ? Self.kind(chars[col]) : 0
        while kind != 0, col < chars.count, Self.kind(chars[col]) == kind { col += 1 }
        while true {
            while col < chars.count, Self.kind(chars[col]) == 0 { col += 1 }
            if col < chars.count { return Position(col: col, row: row) }
            guard row < lastRow else { return from }
            row += 1
            chars = text(row)
            col = 0
        }
    }

    /// `e`: the end of this word, or of the next one when already at an end.
    func endOfWord(_ from: Position) -> Position {
        var row = from.row
        var chars = text(row)
        var col = from.col + 1
        while true {
            while col < chars.count, Self.kind(chars[col]) == 0 { col += 1 }
            if col < chars.count { break }
            guard row < lastRow else { return from }
            row += 1
            chars = text(row)
            col = 0
        }
        let kind = Self.kind(chars[col])
        while col + 1 < chars.count, Self.kind(chars[col + 1]) == kind { col += 1 }
        return Position(col: col, row: row)
    }

    /// `b`: the start of this word, or of the one before when already at a start.
    func previousWord(_ from: Position) -> Position {
        var row = from.row
        var chars = text(row)
        var col = min(from.col, chars.count) - 1
        while true {
            while col >= 0, Self.kind(chars[col]) == 0 { col -= 1 }
            if col >= 0 { break }
            guard row > 0 else { return from }
            row -= 1
            chars = text(row)
            col = chars.count - 1
        }
        let kind = Self.kind(chars[col])
        while col > 0, Self.kind(chars[col - 1]) == kind { col -= 1 }
        return Position(col: col, row: row)
    }

    /// The last character on the row, for `$`.
    func endOfLine(_ row: Int) -> Int {
        max(0, text(row).count - 1)
    }

    /// The next match of `query` after `from`, wrapping around the buffer. Lowercase queries ignore case.
    func find(_ query: String, from: Position, forward: Bool) -> Position? {
        guard !query.isEmpty, lastRow >= 0 else { return nil }
        let options: String.CompareOptions = query == query.lowercased() ? [.caseInsensitive] : []
        let rows = lastRow + 1
        for step in 0...rows {
            let row = ((from.row + (forward ? step : -step)) % rows + rows) % rows
            let string = String(line(row))
            var starts: [Int] = []
            var range = string.startIndex..<string.endIndex
            while let found = string.range(of: query, options: options, range: range) {
                starts.append(string.distance(from: string.startIndex, to: found.lowerBound))
                range = string.index(after: found.lowerBound)..<string.endIndex
            }
            let pick: Int?
            switch (step, forward) {
            case (0, true): pick = starts.first { $0 > from.col }
            case (0, false): pick = starts.last { $0 < from.col }
            case (rows, true): pick = starts.first { $0 <= from.col }
            case (rows, false): pick = starts.last { $0 >= from.col }
            default: pick = forward ? starts.first : starts.last
            }
            if let pick { return Position(col: pick, row: row) }
        }
        return nil
    }
}

/// A pane in copy mode: the view holds still and a block cursor moves over the scrollback with vi keys.
struct CopyMode {
    enum Selecting { case none, characters, lines }

    var cursor: Position
    var anchor = Position(col: 0, row: 0)
    var selecting = Selecting.none
    /// The query being typed after `/` or `?`, and which way it searches.
    var typing: (query: String, forward: Bool)?
    var lastSearch: (query: String, forward: Bool)?
    var note = ""
    let block: PassthroughView
    let mouseReporting: Bool

    /// The pill in the pane header.
    var hint: String {
        if let typing { return (typing.forward ? "/" : "?") + typing.query + "▏" }
        if !note.isEmpty { return note }
        switch selecting {
        case .none: return "v select · / search · q quit"
        case .characters: return "VISUAL · y copy · esc quit"
        case .lines: return "V-LINE · y copy · esc quit"
        }
    }
}

extension AetherTerminal {
    func toggleCopyMode() {
        if copyMode == nil { enterCopyMode() } else { exitCopyMode() }
    }

    private var motion: CopyMotion {
        CopyMotion(line: { [unowned self] in cellText(row: $0) }, lastRow: lastRow)
    }

    /// The bottom row of the buffer.
    private var lastRow: Int {
        var low = 0
        var high = 1
        while terminal.bufferLine(atRow: high) != nil { high *= 2 }
        while low + 1 < high {
            let middle = (low + high) / 2
            if terminal.bufferLine(atRow: middle) != nil { low = middle } else { high = middle }
        }
        return low
    }

    func enterCopyMode() {
        guard copyMode == nil, let terminal else { return }
        let top = terminal.getTopVisibleRow()
        let cursor = terminal.getCursorLocation()
        let start = scrollPosition >= 1 || !canScroll
            ? Position(col: cursor.x, row: top + cursor.y)
            : Position(col: 0, row: top + terminal.rows - 1)
        let block = PassthroughView()
        block.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        block.layer?.borderColor = NSColor.controlAccentColor.cgColor
        block.layer?.borderWidth = 1
        // SwiftTerm re-adds its caret and image layers as it draws. This stays above them.
        block.layer?.zPosition = 10
        addSubview(block)
        copyMode = CopyMode(cursor: start, block: block, mouseReporting: allowMouseReporting)
        // Output keeps landing in the buffer, but the view stays put and does not clear the selection.
        terminal.holdViewport = true
        allowMouseReporting = false
        selection.selectNone()
        refreshCopyMode()
    }

    func exitCopyMode() {
        guard let mode = copyMode else { return }
        mode.block.removeFromSuperview()
        terminal.holdViewport = false
        allowMouseReporting = mode.mouseReporting
        copyMode = nil
        selection.selectNone()
        scroll(toPosition: 1)
        onCopyMode?(nil)
        setNeedsDisplay(bounds)
    }

    /// Every key while in copy mode lands here. Command shortcuts still reach the menus.
    func handleCopyKey(_ event: NSEvent) {
        guard var mode = copyMode, let terminal else { return }
        mode.note = ""
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let typed = event.characters ?? ""

        if var typing = mode.typing {
            switch Int(event.keyCode) {
            case kVK_Escape:
                mode.typing = nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                mode.typing = nil
                mode.lastSearch = typing.query.isEmpty ? mode.lastSearch : typing
                copyMode = mode
                search(again: false)
                return
            case kVK_Delete:
                if typing.query.isEmpty { mode.typing = nil } else { typing.query.removeLast(); mode.typing = typing }
            default:
                if flags.isEmpty, !typed.isEmpty, typed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                    typing.query += typed
                    mode.typing = typing
                }
            }
            copyMode = mode
            refreshCopyMode()
            return
        }

        var cursor = mode.cursor
        let half = max(1, terminal.rows / 2)
        if flags == .control {
            switch event.charactersIgnoringModifiers {
            case "u": cursor.row -= half; scrollUp(lines: half)
            case "d": cursor.row += half; scrollDown(lines: half)
            case "c": exitCopyMode(); return
            default: break
            }
        } else {
            switch Int(event.keyCode) {
            case kVK_Escape: exitCopyMode(); return
            case kVK_Return, kVK_ANSI_KeypadEnter: yank(); return
            case kVK_LeftArrow: cursor.col -= 1
            case kVK_RightArrow: cursor.col += 1
            case kVK_UpArrow: cursor.row -= 1
            case kVK_DownArrow: cursor.row += 1
            default:
                switch typed {
                case "h": cursor.col -= 1
                case "l": cursor.col += 1
                case "k": cursor.row -= 1
                case "j": cursor.row += 1
                case "w": cursor = motion.nextWord(cursor)
                case "b": cursor = motion.previousWord(cursor)
                case "e": cursor = motion.endOfWord(cursor)
                case "0": cursor.col = 0
                case "$": cursor.col = motion.endOfLine(cursor.row)
                case "g": cursor = Position(col: 0, row: 0)
                case "G": cursor = Position(col: 0, row: lastRow)
                case "v", "V":
                    let next: CopyMode.Selecting = typed == "v" ? .characters : .lines
                    mode.selecting = mode.selecting == next ? .none : next
                    mode.anchor = cursor
                case "y": yank(); return
                case "q": exitCopyMode(); return
                case "/", "?": mode.typing = ("", typed == "/")
                case "n", "N":
                    copyMode = mode
                    search(again: true, reverse: typed == "N")
                    return
                default: break
                }
            }
        }
        mode.cursor = cursor
        copyMode = mode
        refreshCopyMode()
    }

    private func search(again: Bool, reverse: Bool = false) {
        guard var mode = copyMode, let last = mode.lastSearch else { return }
        let forward = reverse ? !last.forward : last.forward
        if let found = motion.find(last.query, from: mode.cursor, forward: forward) {
            mode.cursor = found
        } else {
            mode.note = "Not found: \(last.query)"
        }
        copyMode = mode
        refreshCopyMode()
    }

    /// Copies the selection, or the cursor's row when nothing is selected, and leaves copy mode.
    private func yank() {
        guard let mode = copyMode else { return }
        if mode.selecting == .none {
            let row = String(cellText(row: mode.cursor.row)).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            copyToPasteboard(row + "\n")
        } else if let text = getSelection(), !text.isEmpty {
            copyToPasteboard(text)
        }
        exitCopyMode()
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Keeps the cursor in the buffer and on screen, then redraws the block, the selection, and the pill.
    func refreshCopyMode() {
        guard var mode = copyMode, let terminal else { return }
        let bottom = lastRow
        mode.cursor.row = min(max(0, mode.cursor.row), bottom)
        mode.cursor.col = min(max(0, mode.cursor.col), terminal.cols - 1)
        copyMode = mode
        let top = terminal.getTopVisibleRow()
        if mode.cursor.row < top {
            scrollTo(row: mode.cursor.row)
        } else if mode.cursor.row >= top + terminal.rows {
            scrollTo(row: mode.cursor.row - terminal.rows + 1)
        }
        switch mode.selecting {
        case .none:
            selection.selectNone()
        case .characters:
            let (low, high) = Position.compare(mode.anchor, mode.cursor) == .after ? (mode.cursor, mode.anchor) : (mode.anchor, mode.cursor)
            selection.setSelection(start: low, end: Position(col: high.col + 1, row: high.row))
        case .lines:
            let low = min(mode.anchor.row, mode.cursor.row)
            let high = max(mode.anchor.row, mode.cursor.row)
            let end = high < bottom ? Position(col: 0, row: high + 1) : Position(col: terminal.cols, row: high)
            selection.setSelection(start: Position(col: 0, row: low), end: end)
        }
        placeCopyBlock()
        onCopyMode?(mode.hint)
        setNeedsDisplay(bounds)
    }

    /// Moves the block over the cursor's cell. It hides when that row is scrolled out of view.
    func placeCopyBlock() {
        guard let mode = copyMode, let terminal else { return }
        let size = caretFrame.size
        let screenRow = mode.cursor.row - terminal.getTopVisibleRow()
        mode.block.isHidden = screenRow < 0 || screenRow >= terminal.rows || size.width <= 0
        mode.block.frame = NSRect(x: CGFloat(mode.cursor.col) * size.width,
                                  y: bounds.height - CGFloat(screenRow + 1) * size.height,
                                  width: size.width, height: size.height)
    }
}
