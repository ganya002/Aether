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
    case arrangeWindows
    case broadcast
    case settings
    case find
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
final class CommandPalette: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onPick: ((PaletteRow) -> Void)?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [PaletteRow] = []

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .fullSizeContentView, .closable],
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

        let glass = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = 18
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        let host = NSView(frame: glass.bounds)
        host.autoresizingMask = [.width, .height]
        glass.contentView = host
        panel.contentView = glass

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
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 2)
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
        if let parent = NSApp.keyWindow?.frame {
            let size = window?.frame.size ?? NSSize(width: 560, height: 420)
            let origin = NSPoint(x: parent.midX - size.width / 2, y: parent.maxY - size.height - 48)
            window?.setFrameOrigin(origin)
        } else {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("row"), owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = NSUserInterfaceItemIdentifier("row")
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.translatesAutoresizingMaskIntoConstraints = false
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.tag = 2
            view.addSubview(title)
            view.addSubview(detail)
            view.textField = title
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                title.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            ])
            return view
        }()
        cell.textField?.stringValue = item.title
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = item.detail
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
            close()
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
        close()
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
        let actions = Self.actions
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

    private static let actions: [PaletteRow] = [
        PaletteRow(title: "New terminal", detail: "⌘T", kind: .action(.newPane)),
        PaletteRow(title: "New window", detail: "⌘N", kind: .action(.newWindow)),
        PaletteRow(title: "Split right", detail: "⌘D", kind: .action(.splitRight)),
        PaletteRow(title: "Split down", detail: "⌘⇧D", kind: .action(.splitDown)),
        PaletteRow(title: "Close terminal", detail: "⌘W", kind: .action(.close)),
        PaletteRow(title: "Fill window", detail: "⌘↩", kind: .action(.maximize)),
        PaletteRow(title: "Equalize splits", detail: "⌘⇧=", kind: .action(.equalize)),
        PaletteRow(title: "Tile columns", detail: "Arrange the panes", kind: .action(.columns)),
        PaletteRow(title: "Tile rows", detail: "Arrange the panes", kind: .action(.rows)),
        PaletteRow(title: "Tile grid", detail: "Arrange the panes", kind: .action(.grid)),
        PaletteRow(title: "Arrange windows", detail: "Grid the glass windows on this screen", kind: .action(.arrangeWindows)),
        PaletteRow(title: "Broadcast keys", detail: "⌘B", kind: .action(.broadcast)),
        PaletteRow(title: "Settings", detail: "⌘,", kind: .action(.settings)),
        PaletteRow(title: "Find", detail: "⌘F", kind: .action(.find)),
    ]
}

@MainActor
final class SettingsController: NSWindowController {
    private let shade = NSSlider()
    private let radius = NSSlider()
    private let gap = NSSlider()
    private let font = NSSlider()
    private let glass = NSPopUpButton()
    private let text = NSPopUpButton()
    private let snap = NSButton(checkboxWithTitle: "Snap windows to each other when you let go", target: nil, action: nil)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        super.init(window: panel)

        let effect = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.style = .regular
        effect.cornerRadius = 18
        let host = NSView(frame: effect.bounds)
        host.autoresizingMask = [.width, .height]
        effect.contentView = host
        panel.contentView = effect

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 48),
        ])

        stack.addArrangedSubview(row("Glass", glass))
        stack.addArrangedSubview(row("Text", text))
        stack.addArrangedSubview(sliderRow("Shade", shade, min: 0, max: 0.82))
        stack.addArrangedSubview(sliderRow("Corners", radius, min: 8, max: 32))
        stack.addArrangedSubview(sliderRow("Gap", gap, min: 4, max: 22))
        stack.addArrangedSubview(sliderRow("Font", font, min: 10, max: 24))
        snap.target = self
        snap.action = #selector(changed)
        stack.addArrangedSubview(snap)

        let note = NSTextField(wrappingLabelWithString: "Shade is only there so the type stays readable. Clear glass is the window server bending whatever is actually behind Aether.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(note)

        glass.target = self
        glass.action = #selector(changed)
        text.target = self
        text.action = #selector(changed)
        for slider in [shade, radius, gap, font] {
            slider.target = self
            slider.action = #selector(changed)
            slider.isContinuous = true
        }
        glass.addItems(withTitles: GlassStyle.allCases.map(\.title))
        text.addItems(withTitles: TextTone.allCases.map(\.title))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        let settings = AppModel.shared.settings
        shade.doubleValue = settings.shade
        radius.doubleValue = settings.cornerRadius
        gap.doubleValue = settings.gap
        font.doubleValue = settings.fontSize
        glass.selectItem(at: GlassStyle.allCases.firstIndex(of: settings.glass) ?? 0)
        text.selectItem(at: TextTone.allCases.firstIndex(of: settings.text) ?? 0)
        snap.state = settings.snapWindows ? .on : .off
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func changed() {
        AppModel.shared.updateSettings { settings in
            settings.shade = shade.doubleValue
            settings.cornerRadius = radius.doubleValue
            settings.gap = gap.doubleValue
            settings.fontSize = font.doubleValue
            settings.glass = GlassStyle.allCases[glass.indexOfSelectedItem]
            settings.text = TextTone.allCases[text.indexOfSelectedItem]
            settings.snapWindows = snap.state == .on
        }
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let line = NSStackView(views: [label, control])
        line.orientation = .horizontal
        line.alignment = .centerY
        return line
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, min: Double, max: Double) -> NSView {
        slider.minValue = min
        slider.maxValue = max
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return row(title, slider)
    }
}

@MainActor
final class ShortcutController: NSWindowController {
    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shortcuts"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        super.init(window: panel)
        let effect = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.style = .regular
        effect.cornerRadius = 18
        let text = NSTextView(frame: effect.bounds.insetBy(dx: 18, dy: 36))
        text.autoresizingMask = [.width, .height]
        text.isEditable = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = """
        ⌘N          New window
        ⌘T          New terminal
        ⌘D          Split right
        ⌘⇧D         Split down
        ⌘W          Close terminal
        ⌘⇧W         Close window
        ⌘K          Launch a command
        ⌘F          Find
        ⌘↩          Fill the window with the focused terminal
        ⌘⌥ arrows   Focus the neighbor
        ⌘⇧ arrows   Resize the split
        ⌘⇧E         Equalize splits
        ⌘B          Broadcast keys to every terminal in the window
        ⌘,          Settings
        ⌘+  ⌘-     Font size

        Drag the dots on a pane to drop it on an edge, swap it, or pull it out into its own window. Drag the pane’s title to move the window. Hold ⌥ while letting go to skip snapping.

        Ctrl still belongs to the shell.
        """
        let host = NSView(frame: effect.bounds)
        host.autoresizingMask = [.width, .height]
        host.addSubview(text)
        effect.contentView = host
        panel.contentView = effect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        showWindow(nil)
    }
}
