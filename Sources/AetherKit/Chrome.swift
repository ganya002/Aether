import AppKit

/// Launcher entries that are not key-bound actions.
enum PaletteAction: Equatable {
    case app(AppAction)
    case layout(LayoutKind)
    case arrangeWindows
    case checkForUpdates
    case glass(GlassStyle)
    case help
}

struct PaletteRow: Equatable {
    enum Kind: Equatable {
        case command(String, newWindow: Bool)
        case tool(String)
        case action(PaletteAction)
    }

    enum Section: String, Equatable {
        case actions = "Actions"
        case run = "Run"
        case recent = "Recent"
        case tools = "Tools"
    }

    var title: String
    var detail: String
    var kind: Kind
    var section: Section = .actions
    /// An SF Symbol name.
    var symbol: String = ""
    /// The shortcut, drawn as a keycap on the right.
    var shortcut: String = ""
    /// Other words that should find this row, like "preferences" for Settings.
    var keywords: [String] = []

    var runs: Bool {
        if case .action = kind { return false }
        return true
    }
}

/// Orders launcher rows. A query that names an action opens it; anything that looks like a command runs.
enum Launcher {
    struct Match {
        var row: PaletteRow
        var score: Double
        var strong: Bool
        var prefix: Bool
    }

    static func rows(
        query rawQuery: String,
        actions: [PaletteRow],
        tools: [(name: String, path: String)],
        recents: [String],
        hosts: [String]
    ) -> [PaletteRow] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolRows = tools.map {
            PaletteRow(title: $0.name, detail: $0.path, kind: .tool($0.name), section: .tools, symbol: "terminal")
        }
        let hostRows = hosts.map {
            PaletteRow(title: "ssh \($0)", detail: "From ~/.ssh/config", kind: .command("ssh \($0)", newWindow: false), section: .tools, symbol: "network")
        }
        let recentRows = recents.map {
            PaletteRow(title: $0, detail: "Ran recently", kind: .command($0, newWindow: false), section: .recent, symbol: "clock.arrow.circlepath")
        }
        if query.isEmpty {
            return Array(recentRows.prefix(6)) + actions + Array(toolRows.prefix(8)) + Array(hostRows.prefix(4))
        }

        let matches = actions.compactMap { match(query, $0) }.sorted { lhs, rhs in
            if lhs.strong != rhs.strong { return lhs.strong }
            return lhs.score > rhs.score
        }
        let actionRows = matches.map(\.row)
        let run = [
            PaletteRow(title: "Run “\(query)”", detail: "In the focused window", kind: .command(query, newWindow: false), section: .run, symbol: "play"),
            PaletteRow(title: "Run “\(query)” in a new window", detail: "Its own glass window", kind: .command(query, newWindow: true), section: .run, symbol: "macwindow.badge.plus"),
        ]
        let lowered = query.lowercased()
        let recent = recentRows.filter { row in
            let text = row.title.lowercased()
            return text != lowered && (text.contains(lowered) || Fuzzy.score(query, text) != nil)
        }.prefix(5)
        let extra = Fuzzy.rank(query, toolRows + hostRows) { $0.title }

        if actionFirst(query, best: matches.first) {
            return actionRows + run + recent + extra
        }
        return run + recent + actionRows + extra
    }

    /// An action leads when the query reads as its name. A space or a slash reads as a command,
    /// unless the whole query is the start of an action's name ("split right").
    static func actionFirst(_ query: String, best: Match?) -> Bool {
        guard let best, best.strong else { return false }
        if best.prefix { return true }
        if query.contains(" ") || query.contains("/") { return false }
        return true
    }

    static func match(_ query: String, _ row: PaletteRow) -> Match? {
        let q = query.lowercased()
        var best: Match?
        for (index, raw) in ([row.title] + row.keywords).enumerated() {
            let text = raw.lowercased()
            // The title counts a little more than a keyword.
            let bias: Double = index == 0 ? 5 : 0
            var candidate: Match?
            if text.hasPrefix(q) {
                candidate = Match(row: row, score: 1000 + bias - Double(text.count), strong: true, prefix: true)
            } else if text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }).contains(where: { $0.hasPrefix(q) }) {
                candidate = Match(row: row, score: 800 + bias - Double(text.count), strong: true, prefix: false)
            } else if let score = Fuzzy.score(q, text) {
                let tight = q.count >= 3 && score >= Double(q.count) * 18
                candidate = Match(row: row, score: score + bias, strong: tight, prefix: false)
            }
            if let candidate, candidate.score > (best?.score ?? -.infinity) {
                best = candidate
            }
        }
        return best
    }
}

/// Commands the launcher ran, newest first.
enum LauncherRecents {
    static let key = "aether.launcher.recent"
    static let limit = 20

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func remember(_ command: String, _ defaults: UserDefaults = .standard) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(adding(trimmed, to: load(defaults)), forKey: key)
    }

    static func adding(_ command: String, to list: [String]) -> [String] {
        Array(([command] + list.filter { $0 != command }).prefix(limit))
    }
}

enum SSHConfig {
    /// Concrete `Host` names. Patterns with wildcards or negation are not places to connect to.
    static func hosts(in text: String) -> [String] {
        var found: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let keyword = tokens.first, keyword.lowercased() == "host" else { continue }
            for name in tokens.dropFirst() {
                let name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !name.isEmpty, !name.contains(where: { "*?!".contains($0) }), !found.contains(name) else { continue }
                found.append(name)
            }
        }
        return found
    }

    static func load() -> [String] {
        let url = URL(fileURLWithPath: System.home()).appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return hosts(in: text)
    }
}

/// Installed tools, found on the login shell's PATH once instead of on every keystroke.
final class ToolShelf: @unchecked Sendable {
    static let shared = ToolShelf()
    private let lock = NSLock()
    private var tools: [(name: String, path: String)]?
    private var resolving = false

    /// Starts looking in the background. Until it finishes, the app's own PATH stands in.
    func warm() {
        lock.lock()
        guard !resolving else {
            lock.unlock()
            return
        }
        resolving = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            var paths = System.searchPaths()
            for extra in Self.loginPath() where !paths.contains(extra) {
                paths.insert(extra, at: 0)
            }
            let found = System.installedTools(in: paths)
            self.lock.lock()
            self.tools = found
            self.lock.unlock()
        }
    }

    func current() -> [(name: String, path: String)] {
        lock.lock()
        let cached = tools
        lock.unlock()
        if let cached { return cached }
        warm()
        let fallback = System.installedTools()
        lock.lock()
        if tools == nil { tools = fallback }
        lock.unlock()
        return fallback
    }

    /// `$SHELL -lic 'printf %s "$PATH"'`, given two seconds. Output goes to a file so a
    /// background job the shell leaves behind cannot hold a pipe open.
    static func loginPath(timeout: TimeInterval = 2) -> [String] {
        let marker = "__AETHER_PATH__"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("aether-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: output.path) else { return [] }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: System.userShell())
        task.arguments = ["-lic", "printf '\(marker)%s' \"$PATH\""]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = handle
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch { return [] }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // An interactive shell ignores SIGTERM.
            kill(task.processIdentifier, SIGKILL)
            return []
        }
        guard let text = try? String(contentsOf: output, encoding: .utf8),
              let range = text.range(of: marker, options: .backwards) else { return [] }
        return text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
    }
}

extension AppAction {
    var group: ShortcutGroup { ShortcutGroup.of(self) }

    var symbolName: String {
        switch self {
        case .newWindow: "macwindow.badge.plus"
        case .newPane: "plus.rectangle"
        case .newTab: "plus.square.on.square"
        case .closeTab: "minus.square"
        case .nextTab: "chevron.right.to.line"
        case .previousTab: "chevron.left.to.line"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .closePane: "xmark.rectangle"
        case .closeWindow: "xmark.square"
        case .launch: "command"
        case .clearBuffer: "eraser"
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .equalize: "equal.square"
        case .nextLayout: "rectangle.3.group"
        case .previousLayout: "rectangle.3.group"
        case .focusLeft: "arrow.left.circle"
        case .focusRight: "arrow.right.circle"
        case .focusUp: "arrow.up.circle"
        case .focusDown: "arrow.down.circle"
        case .growLeft: "arrow.left.to.line"
        case .growRight: "arrow.right.to.line"
        case .growUp: "arrow.up.to.line"
        case .growDown: "arrow.down.to.line"
        case .broadcast: "dot.radiowaves.left.and.right"
        case .fontUp: "textformat.size.larger"
        case .fontDown: "textformat.size.smaller"
        case .fontReset: "textformat.size"
        case .find: "magnifyingglass"
        case .findNext: "chevron.down"
        case .findPrevious: "chevron.up"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .selectAll: "selection.pin.in.out"
        case .settings: "gearshape"
        case .dropdown: "rectangle.topthird.inset.filled"
        case .quit: "power"
        case .insertPath: "folder"
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            "\(paneNumber ?? 1).square"
        case .previousPane: "chevron.left.square"
        case .nextPane: "chevron.right.square"
        case .swapNext: "arrow.left.arrow.right"
        case .movePaneToWindow: "macwindow.on.rectangle"
        case .renamePane: "pencil"
        case .restartPane: "arrow.clockwise"
        case .shortcuts: "keyboard"
        case .previousPrompt: "arrow.up.to.line"
        case .nextPrompt: "arrow.down.to.line"
        case .selectLastOutput: "text.badge.checkmark"
        case .copyMode: "character.cursor.ibeam"
        }
    }

    /// Clipboard and find-again keys need a terminal to act on, and the launcher would be in the way.
    var inLauncher: Bool {
        switch self {
        case .launch, .copy, .paste, .selectAll, .findNext, .findPrevious, .quit,
             .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            false
        default:
            true
        }
    }

    var keywords: [String] {
        switch self {
        case .settings: ["preferences", "options", "config"]
        case .clearBuffer: ["clear", "cls", "reset"]
        case .copyMode: ["vi", "vim", "tmux", "select", "keyboard"]
        case .fill: ["maximize", "zoom"]
        case .newPane: ["shell"]
        case .newTab: ["tab", "workspace", "group"]
        case .closeTab: ["workspace"]
        case .nextTab: ["workspace"]
        case .previousTab: ["workspace"]
        case .broadcast: ["sync", "all panes"]
        case .dropdown: ["quake", "hotkey", "visor"]
        case .renamePane: ["title", "name"]
        case .movePaneToWindow: ["detach", "pop out"]
        case .shortcuts: ["keys", "keybindings", "hotkeys"]
        default: []
        }
    }
}

@MainActor
final class CommandPalette: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    enum Item: Equatable {
        case header(String)
        case row(PaletteRow)
    }

    var onPick: ((PaletteRow) -> Void)?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var items: [Item] = []
    private var vaporToken = 0
    private var hosts: [String] = []

    init() {
        let panel = VaporPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.title = "Launch"
        super.init(window: panel)
        panel.delegate = self

        let glass = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = 18
        glass.enableInteractiveGlass()
        let host = NSView(frame: glass.bounds)
        host.autoresizingMask = [.width, .height]
        glass.contentView = host
        GlassPanel.mount(glass, on: panel, radius: 18)

        field.placeholderString = "Launch a command, or search"
        field.font = .systemFont(ofSize: 16, weight: .medium)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .labelColor
        field.delegate = self
        field.setAccessibilityLabel("Launch a command, or search actions")
        field.frame = NSRect(x: 18, y: host.bounds.height - 58, width: host.bounds.width - 36, height: 28)
        field.autoresizingMask = [.width, .minYMargin]
        host.addSubview(field)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 18, y: 10, width: host.bounds.width - 36, height: 16)
        hint.autoresizingMask = [.width, .maxYMargin]
        host.addSubview(hint)

        scroll.frame = NSRect(x: 8, y: 32, width: host.bounds.width - 16, height: host.bounds.height - 100)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = ""
        column.width = 564
        column.minWidth = 200
        column.maxWidth = 4000
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.refusesFirstResponder = true
        table.selectionHighlightStyle = .regular
        table.target = self
        table.doubleAction = #selector(activateSelected)
        table.setAccessibilityLabel("Launcher results")
        scroll.documentView = table
        host.addSubview(scroll)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        field.stringValue = ""
        hosts = SSHConfig.load()
        reload()
        vaporToken += 1
        if let parent = NSApp.keyWindow?.frame {
            let size = NSSize(width: 580, height: 440)
            let origin = NSPoint(x: parent.midX - size.width / 2, y: parent.maxY - size.height - 48)
            window?.setFrame(NSRect(origin: origin, size: size), display: false)
        } else {
            window?.center()
        }
        if let glass = window?.contentView as? NSGlassEffectView {
            glass.style = AppModel.shared.settings.glass == .clear ? .clear : .regular
        }
        guard let window else { return }
        fitColumn()
        GlassMotion.present(window)
        window.makeFirstResponder(field)
        DispatchQueue.main.async { [weak self] in self?.fitColumn() }
    }

    func windowDidResignKey(_ notification: Notification) {
        vaporize()
    }

    func vaporize() {
        guard let window, window.isVisible, window.alphaValue > 0.2 else { return }
        vaporToken += 1
        let token = vaporToken
        GlassMotion.vaporize(window) { [weak self] in self?.vaporToken == token }
    }

    private func fitColumn() {
        guard let column = table.tableColumns.first else { return }
        let width = max(320, scroll.bounds.width)
        column.width = width
        table.frame.size.width = width
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .row = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 22 }
        return 42
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("header"), owner: self) as? PaletteHeaderView ?? PaletteHeaderView()
            cell.label.stringValue = title.uppercased()
            cell.label.setAccessibilityLabel(title)
            return cell
        case .row(let item):
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("row"), owner: self) as? PaletteRowView ?? PaletteRowView()
            cell.show(item)
            fitColumn()
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshHint()
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            move(1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            move(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            activateSelected()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            vaporize()
            return true
        }
        return false
    }

    private var selectedRow: PaletteRow? {
        let index = table.selectedRow
        guard items.indices.contains(index), case .row(let row) = items[index] else { return nil }
        return row
    }

    @objc private func activateSelected() {
        guard var row = selectedRow else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            switch row.kind {
            case .command(let command, _): row.kind = .command(command, newWindow: true)
            case .tool(let name): row.kind = .command(name, newWindow: true)
            case .action: break
            }
        }
        vaporize()
        onPick?(row)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        var next = table.selectedRow
        repeat {
            next += delta
        } while items.indices.contains(next) && !isRow(next)
        guard items.indices.contains(next) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func isRow(_ index: Int) -> Bool {
        if case .row = items[index] { return true }
        return false
    }

    private func reload() {
        items = Self.items(for: Self.rows(for: field.stringValue, hosts: hosts))
        table.reloadData()
        if let first = items.indices.first(where: isRow) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(max(0, first - 1))
        }
        refreshHint()
    }

    private func refreshHint() {
        guard let row = selectedRow else {
            hint.stringValue = "type a command to run it      esc  close"
            return
        }
        hint.stringValue = row.runs
            ? "↩  run here      ⌘↩  new window      esc  close"
            : "↩  open      esc  close"
    }

    /// Section headers go in front of each run of rows from the same section.
    static func items(for rows: [PaletteRow]) -> [Item] {
        var items: [Item] = []
        var section: PaletteRow.Section?
        for row in rows {
            if row.section != section {
                section = row.section
                items.append(.header(row.section.rawValue))
            }
            items.append(.row(row))
        }
        return items
    }

    static func rows(for query: String, hosts: [String]? = nil) -> [PaletteRow] {
        Launcher.rows(
            query: query,
            actions: actions(),
            tools: ToolShelf.shared.current(),
            recents: LauncherRecents.load(),
            hosts: hosts ?? []
        )
    }

    static func actions() -> [PaletteRow] {
        let keys = AppModel.shared.settings.keys
        var rows = AppAction.allCases.filter(\.inLauncher).map { action in
            let chord = keys.chord(action)
            return PaletteRow(
                title: action.title,
                detail: "",
                kind: .action(.app(action)),
                symbol: action.symbolName,
                shortcut: chord.key.isEmpty ? "" : chord.symbol,
                keywords: action.keywords
            )
        }
        for kind in LayoutKind.cycle {
            rows.append(PaletteRow(title: "\(kind.title) layout", detail: "Arrange the panes", kind: .action(.layout(kind)), symbol: "rectangle.3.group", keywords: ["tile", "arrange"]))
        }
        rows.append(PaletteRow(title: "Arrange windows", detail: "Grid the glass windows on this screen", kind: .action(.arrangeWindows), symbol: "square.grid.2x2", keywords: ["tile windows"]))
        let clear = AppModel.shared.settings.glass == .clear
        rows.append(PaletteRow(
            title: clear ? "Use regular glass" : "Use clear glass",
            detail: clear ? "Frost the glass behind the text" : "See more of what is behind the window",
            kind: .action(.glass(clear ? .regular : .clear)),
            symbol: "drop",
            keywords: ["glass", "transparency"]
        ))
        rows.append(PaletteRow(title: "Check for updates", detail: "", kind: .action(.checkForUpdates), symbol: "arrow.down.circle", keywords: ["upgrade", "version"]))
        rows.append(PaletteRow(title: "Aether help", detail: "Open the README on GitHub", kind: .action(.help), symbol: "questionmark.circle", keywords: ["docs", "manual"]))
        return rows
    }
}

final class PaletteHeaderView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("header")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: 2, width: max(0, bounds.width - 28), height: 14)
    }
}

final class PaletteRowView: NSTableCellView {
    let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let keycap = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("row")
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.isEditable = false
        title.isBordered = false
        title.drawsBackground = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        keycap.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        keycap.textColor = .secondaryLabelColor
        keycap.alignment = .center
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 5
        keycap.layer?.borderWidth = 1
        textField = title
        imageView = icon
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
        addSubview(keycap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ row: PaletteRow) {
        textField?.stringValue = row.title
        detail.stringValue = row.detail
        icon.image = row.symbol.isEmpty ? nil : NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        keycap.stringValue = row.shortcut
        keycap.isHidden = row.shortcut.isEmpty
        setAccessibilityLabel(row.shortcut.isEmpty ? row.title : "\(row.title), \(row.shortcut)")
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            keycap.layer?.borderColor = NSColor.separatorColor.cgColor
            keycap.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        }
        icon.frame = NSRect(x: 14, y: (bounds.height - 18) / 2, width: 18, height: 18)
        var right = bounds.width - 14
        if !keycap.isHidden {
            let width = ceil(keycap.intrinsicContentSize.width) + 12
            keycap.frame = NSRect(x: right - width, y: (bounds.height - 18) / 2, width: width, height: 18)
            right = keycap.frame.minX - 10
        }
        let x: CGFloat = 42
        let width = max(0, right - x)
        if detail.stringValue.isEmpty {
            textField?.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: width, height: 16)
            detail.frame = .zero
        } else {
            textField?.frame = NSRect(x: x, y: bounds.height - 22, width: width, height: 16)
            detail.frame = NSRect(x: x, y: 4, width: width, height: 14)
        }
    }
}

/// Every shortcut, grouped, from the live key map.
@MainActor
final class ShortcutController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Item {
        case header(String)
        case entry(title: String, keys: String)
    }

    var onCustomize: (() -> Void)?
    private var vaporToken = 0
    private let search = NSSearchField()
    private let table = NSTableView()
    private var items: [Item] = []

    init() {
        let panel = VaporPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard Shortcuts"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self
        let effect = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.style = .regular
        effect.cornerRadius = 18
        let host = NSView(frame: effect.bounds)
        host.autoresizingMask = [.width, .height]

        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.frame = NSRect(x: 20, y: host.bounds.height - 44, width: 220, height: 22)
        heading.autoresizingMask = [.minYMargin]
        host.addSubview(heading)

        search.placeholderString = "Search shortcuts"
        search.delegate = self
        search.frame = NSRect(x: host.bounds.width - 240, y: host.bounds.height - 46, width: 220, height: 26)
        search.autoresizingMask = [.minXMargin, .minYMargin]
        host.addSubview(search)

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 92, width: host.bounds.width - 20, height: host.bounds.height - 150))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.width = 330
        let keys = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keys"))
        keys.width = 150
        table.addTableColumn(name)
        table.addTableColumn(keys)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 24
        table.selectionHighlightStyle = .none
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Keyboard shortcuts")
        scroll.documentView = table
        host.addSubview(scroll)

        let tips = NSTextField(wrappingLabelWithString: "Drag ⠿ on a pane to drop it on an edge, swap it, or pull it into its own window. Drop a file on a terminal to paste its path. ⌘-click a path to open it.")
        tips.font = .systemFont(ofSize: 11)
        tips.textColor = .secondaryLabelColor
        tips.frame = NSRect(x: 20, y: 44, width: host.bounds.width - 40, height: 42)
        tips.autoresizingMask = [.width, .maxYMargin]
        host.addSubview(tips)

        let customize = NSButton(title: "Customize…", target: self, action: #selector(customizePressed))
        customize.bezelStyle = .rounded
        customize.sizeToFit()
        customize.frame.origin = NSPoint(x: host.bounds.width - customize.frame.width - 18, y: 12)
        customize.autoresizingMask = [.minXMargin, .maxYMargin]
        host.addSubview(customize)

        effect.contentView = host
        GlassPanel.mount(effect, on: panel, radius: 18)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        search.stringValue = ""
        reload()
        vaporToken += 1
        window?.center()
        guard let window else { return }
        if let glass = window.contentView as? NSGlassEffectView {
            glass.style = AppModel.shared.settings.glass == .clear ? .clear : .regular
        }
        GlassMotion.present(window)
        window.makeFirstResponder(search)
    }

    func windowDidResignKey(_ notification: Notification) {
        vaporize()
    }

    override func cancelOperation(_ sender: Any?) {
        vaporize()
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if search.stringValue.isEmpty {
            vaporize()
        } else {
            search.stringValue = ""
            reload()
        }
        return true
    }

    @objc private func customizePressed() {
        vaporize()
        onCustomize?()
    }

    private func reload() {
        items = Self.items(query: search.stringValue, keys: AppModel.shared.settings.keys)
        table.reloadData()
    }

    static func items(query: String, keys: KeyMap) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items: [Item] = []
        for group in ShortcutGroup.allCases {
            let entries = AppAction.allCases.filter { $0.group == group }.compactMap { action -> Item? in
                let chord = keys.chord(action)
                let shown = chord.key.isEmpty ? "—" : chord.symbol
                guard query.isEmpty || action.title.lowercased().contains(query) || shown.lowercased().contains(query)
                    || action.keywords.contains(where: { $0.contains(query) }) else { return nil }
                return .entry(title: action.title, keys: shown)
            }
            guard !entries.isEmpty else { continue }
            items.append(.header(group.title))
            items.append(contentsOf: entries)
        }
        return items
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        switch items[row] {
        case .header(let title):
            label.stringValue = title.uppercased()
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            label.setAccessibilityLabel(title)
        case .entry(let title, let keys):
            if tableColumn?.identifier.rawValue == "keys" {
                label.stringValue = keys
                label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                label.textColor = .secondaryLabelColor
                label.alignment = .right
            } else {
                label.stringValue = title
                label.font = .systemFont(ofSize: 13)
                label.textColor = .labelColor
            }
        }
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func vaporize() {
        guard let window, window.isVisible, window.alphaValue > 0.2 else { return }
        vaporToken += 1
        let token = vaporToken
        GlassMotion.vaporize(window) { [weak self] in self?.vaporToken == token }
    }
}

/// Rename Terminal. An empty name hands the title back to the shell.
@MainActor
enum RenameSheet {
    static func present(paneID: String) {
        guard let pane = AppModel.shared.panes[paneID], let window = pane.chrome.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Terminal"
        alert.informativeText = "Leave it empty to show the title the shell sets."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pane.customTitle ?? ""
        field.placeholderString = pane.title
        field.setAccessibilityLabel("Terminal name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                AppModel.shared.rename(paneID, to: field.stringValue)
            }
            window.makeFirstResponder(pane.chrome.terminal)
        }
    }
}

/// A one-time strip of the keys worth knowing, in the first pane of the first window.
@MainActor
final class OnboardingStrip: NSView {
    static let dismissedKey = "aether.onboardingDismissed"
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()

    static var wanted: Bool {
        !UserDefaults.standard.bool(forKey: dismissedKey)
    }

    static func attach(to chrome: PaneChrome) {
        guard wanted, !chrome.subviews.contains(where: { $0 is OnboardingStrip }) else { return }
        let strip = OnboardingStrip(frame: NSRect(x: 10, y: chrome.bounds.height - 34 - 34, width: max(120, chrome.bounds.width - 20), height: 28))
        strip.autoresizingMask = [.width, .minYMargin]
        chrome.addSubview(strip)
        NSAccessibility.post(element: strip, notification: .layoutChanged)
    }

    static func text(keys: KeyMap) -> String {
        func key(_ action: AppAction) -> String {
            let chord = keys.chord(action)
            return chord.key.isEmpty ? "" : chord.symbol
        }
        let parts = [
            (key(.launch), "launch"),
            (key(.splitRight), "split"),
            (key(.clearBuffer), "clear"),
            ("drag ⠿", "to move"),
            (key(.dropdown), "dropdown"),
            (key(.settings), "settings"),
        ]
        return parts.filter { !$0.0.isEmpty }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.stringValue = Self.text(keys: AppModel.shared.settings.keys)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss tips")
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        close.target = self
        close.action = #selector(dismiss)
        close.setAccessibilityLabel("Dismiss tips")
        close.refusesFirstResponder = true
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tips: " + label.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: bounds.width - 26, y: (bounds.height - 18) / 2, width: 18, height: 18)
        label.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 46), height: 16)
    }

    override func accessibilityChildren() -> [Any]? { [close] }

    @objc private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        Motion.group(Motion.close, {
            self.animator().alphaValue = 0
        }, done: {
            self.removeFromSuperview()
        })
    }
}

/// The ⠿ grip, as VoiceOver and Full Keyboard Access see it. Mouse drags go to the header underneath.
@MainActor
final class PaneGrip: NSView {
    var paneID: String?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Move terminal" }
    override func accessibilityHelp() -> String? { "Opens a menu to move, swap, or detach this terminal" }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let paneID else { return nil }
        return [
            NSAccessibilityCustomAction(name: "Move to new window") {
                AppModel.shared.moveToNewWindow(paneID)
                return true
            },
            NSAccessibilityCustomAction(name: "Swap with next terminal") {
                AppModel.shared.swapWithNext(paneID)
                return true
            },
            NSAccessibilityCustomAction(name: "Rename") {
                RenameSheet.present(paneID: paneID)
                return true
            },
        ]
    }

    private func showMenu() {
        guard let paneID else { return }
        let menu = NSMenu(title: "Move terminal")
        let entries: [(String, () -> Void)] = [
            ("Move to New Window", { AppModel.shared.moveToNewWindow(paneID) }),
            ("Swap with Next Terminal", { AppModel.shared.swapWithNext(paneID) }),
            ("Fill Window", {
                AppModel.shared.focus(pane: paneID)
                AppModel.shared.toggleMaximize()
            }),
            ("Rename…", { RenameSheet.present(paneID: paneID) }),
        ]
        for (title, run) in entries {
            let item = NSMenuItem(title: title, action: #selector(MenuBlock.fire(_:)), keyEquivalent: "")
            let block = MenuBlock(run)
            item.target = block
            item.representedObject = block
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
}

/// A menu item target that runs a closure. The item keeps it alive through representedObject.
@MainActor
final class MenuBlock: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire(_ sender: Any?) {
        run()
    }
}
