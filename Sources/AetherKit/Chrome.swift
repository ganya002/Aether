import AppKit

enum PaletteAction: Equatable {
    case newPane
    case newWindow
    case splitRight
    case splitDown
    case close
    case maximize
    case equalize
    case columns
    case rows
    case grid
    case nextLayout
    case arrangeWindows
    case broadcast
    case settings
    case find
    case dropdown
}

struct PaletteRow: Equatable {
    enum Kind: Equatable {
        case command(String, newWindow: Bool)
        case tool(String)
        case action(PaletteAction)
    }

    var title: String
    var detail: String
    var kind: Kind
}

@MainActor
final class CommandPalette: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var onPick: ((PaletteRow) -> Void)?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [PaletteRow] = []
    private var vaporToken = 0

    init() {
        let panel = VaporPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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
        panel.isMovableByWindowBackground = true
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
        field.frame = NSRect(x: 18, y: host.bounds.height - 58, width: host.bounds.width - 36, height: 28)
        field.autoresizingMask = [.width, .minYMargin]
        host.addSubview(field)

        let hint = NSTextField(labelWithString: "↩  open here      ⌘↩  new window      esc  close")
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
        column.width = 544
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
        scroll.documentView = table
        host.addSubview(scroll)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        field.stringValue = ""
        reload()
        vaporToken += 1
        if let parent = NSApp.keyWindow?.frame {
            let size = NSSize(width: 560, height: 420)
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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("row"), owner: self) as? PaletteRowView ?? PaletteRowView()
        cell.textField?.stringValue = item.title
        cell.detail.stringValue = item.detail
        fitColumn()
        return cell
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

    @objc private func activateSelected() {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        var row = rows[index]
        if case .command(let command, _) = row.kind, NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            row = PaletteRow(title: row.title, detail: row.detail, kind: .command(command, newWindow: true))
        }
        vaporize()
        onPick?(row)
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(0, table.selectedRow + delta), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func reload() {
        rows = Self.rows(for: field.stringValue)
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    static func rows(for rawQuery: String) -> [PaletteRow] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = Self.actions()
        let tools = System.installedTools()
        if query.isEmpty {
            var rows = actions
            rows.append(contentsOf: tools.prefix(8).map {
                PaletteRow(title: $0.name, detail: $0.path, kind: .tool($0.name))
            })
            return rows
        }
        var rows = [
            PaletteRow(title: "Run “\(query)”", detail: "In the focused window", kind: .command(query, newWindow: false)),
            PaletteRow(title: "Run “\(query)” in a new window", detail: "Its own glass window", kind: .command(query, newWindow: true)),
        ]
        rows.append(contentsOf: Fuzzy.rank(query, actions) { $0.title })
        rows.append(contentsOf: Fuzzy.rank(query, tools.map {
            PaletteRow(title: $0.name, detail: $0.path, kind: .tool($0.name))
        }) { $0.title })
        return rows
    }

    private static func actions() -> [PaletteRow] {
        let keys = AppModel.shared.settings.keys
        return [
            PaletteRow(title: "New terminal", detail: keys.symbol(.newPane), kind: .action(.newPane)),
            PaletteRow(title: "New window", detail: keys.symbol(.newWindow), kind: .action(.newWindow)),
            PaletteRow(title: "Split right", detail: keys.symbol(.splitRight), kind: .action(.splitRight)),
            PaletteRow(title: "Split down", detail: keys.symbol(.splitDown), kind: .action(.splitDown)),
            PaletteRow(title: "Close terminal", detail: keys.symbol(.closePane), kind: .action(.close)),
            PaletteRow(title: "Fill window", detail: keys.symbol(.fill), kind: .action(.maximize)),
            PaletteRow(title: "Equalize splits", detail: keys.symbol(.equalize), kind: .action(.equalize)),
            PaletteRow(title: "Tile columns", detail: "Arrange the panes", kind: .action(.columns)),
            PaletteRow(title: "Tile rows", detail: "Arrange the panes", kind: .action(.rows)),
            PaletteRow(title: "Tile grid", detail: "Arrange the panes", kind: .action(.grid)),
            PaletteRow(title: "Next layout", detail: keys.symbol(.nextLayout), kind: .action(.nextLayout)),
            PaletteRow(title: "Arrange windows", detail: "Grid the glass windows on this screen", kind: .action(.arrangeWindows)),
            PaletteRow(title: "Broadcast keys", detail: keys.symbol(.broadcast), kind: .action(.broadcast)),
            PaletteRow(title: "Settings", detail: keys.symbol(.settings), kind: .action(.settings)),
            PaletteRow(title: "Find", detail: keys.symbol(.find), kind: .action(.find)),
            PaletteRow(title: "Dropdown terminal", detail: keys.symbol(.dropdown), kind: .action(.dropdown)),
        ]
    }
}

final class PaletteRowView: NSTableCellView {
    let detail = NSTextField(labelWithString: "")

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
        textField = title
        addSubview(title)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 28)
        textField?.frame = NSRect(x: 14, y: bounds.height - 22, width: width, height: 16)
        detail.frame = NSRect(x: 14, y: 4, width: width, height: 14)
    }
}


@MainActor
final class ShortcutController: NSWindowController, NSWindowDelegate {
    private var vaporToken = 0
    private let text = NSTextView(frame: .zero)
    init() {
        let panel = VaporPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shortcuts"
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
        text.frame = effect.bounds.insetBy(dx: 18, dy: 36)
        text.autoresizingMask = [.width, .height]
        text.isEditable = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = Self.page()
        let host = NSView(frame: effect.bounds)
        host.autoresizingMask = [.width, .height]
        host.addSubview(text)
        effect.contentView = host
        GlassPanel.mount(effect, on: panel, radius: 18)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        text.string = Self.page()
        vaporToken += 1
        window?.center()
        guard let window else { return }
        if let glass = window.contentView as? NSGlassEffectView {
            glass.style = AppModel.shared.settings.glass == .clear ? .clear : .regular
        }
        GlassMotion.present(window)
    }

    func windowDidResignKey(_ notification: Notification) {
        vaporize()
    }

    private static func page() -> String {
        let keys = AppModel.shared.settings.keys
        return """
        \(keys.symbol(.newWindow))    New window
        \(keys.symbol(.newPane))    New terminal
        \(keys.symbol(.splitRight))    Split right
        \(keys.symbol(.splitDown))    Split down
        \(keys.symbol(.closePane))    Close terminal
        \(keys.symbol(.closeWindow))    Close window
        \(keys.symbol(.launch))    Launch a command
        \(keys.symbol(.find))    Find
        \(keys.symbol(.fill))    Fill the window
        \(keys.symbol(.equalize))    Equalize splits
        \(keys.symbol(.nextLayout))    Next layout
        \(keys.symbol(.previousLayout))    Previous layout
        \(keys.symbol(.broadcast))    Broadcast keys
        \(keys.symbol(.dropdown))    Dropdown terminal
        \(keys.symbol(.settings))    Settings

        Drag the dots on a pane to drop it on an edge, swap it, or pull it out into its own window. Drop a file on a terminal to paste its path. Command-click a path to open it.

        Kitty, sixel, and iTerm images render in the pane. Ctrl still belongs to the shell.
        """
    }

    func vaporize() {
        guard let window, window.isVisible, window.alphaValue > 0.2 else { return }
        vaporToken += 1
        let token = vaporToken
        GlassMotion.vaporize(window) { [weak self] in self?.vaporToken == token }
    }
}
