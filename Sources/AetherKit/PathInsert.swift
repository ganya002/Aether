import AppKit

/// A short glass list for inserting a path. Matches stay fuzzy, and the path is pasted at the cursor.
@MainActor
final class PathInsert: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = PathInsert()
    private var window: NSWindow?
    private var field: NSTextField?
    private var table: NSTableView?
    private var files: [String] = []
    private var shown: [String] = []

    static func show() { shared.present() }

    private func present() {
        guard let pane = focusedPane() else { return }
        files = (try? FileManager.default.contentsOfDirectory(atPath: pane.cwd))?.sorted() ?? []
        shown = files
        if window == nil { build() }
        field?.stringValue = ""
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
    }

    private func build() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Insert a path"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let glass = NSGlassEffectView(frame: panel.contentView?.bounds ?? .zero)
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = 16
        let host = NSView(frame: glass.bounds)
        host.autoresizingMask = [.width, .height]
        let field = NSTextField(frame: NSRect(x: 16, y: host.bounds.height - 52, width: host.bounds.width - 32, height: 28))
        field.placeholderString = "Filter files"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.delegate = self
        field.autoresizingMask = [.width, .minYMargin]
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 12, width: host.bounds.width - 16, height: host.bounds.height - 76))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.width = 480
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pick)
        scroll.documentView = table
        host.addSubview(field)
        host.addSubview(scroll)
        glass.contentView = host
        panel.contentView = glass
        self.window = panel
        self.field = field
        self.table = table
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = field?.stringValue ?? ""
        shown = Fuzzy.rank(query, files) { $0 }
        if query.isEmpty { shown = files }
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            pick()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window?.orderOut(nil)
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: shown[row])
        label.font = .systemFont(ofSize: 13)
        return label
    }

    @objc private func pick() {
        let row = table?.selectedRow ?? 0
        guard shown.indices.contains(row), let pane = focusedPane() else { return }
        let path = (pane.cwd as NSString).appendingPathComponent(shown[row])
        pane.chrome.terminal.insertText(ShellPath.quote(path), replacementRange: NSRange(location: 0, length: 0))
        window?.orderOut(nil)
    }

    private func reload() {
        table?.reloadData()
        if !shown.isEmpty { table?.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func focusedPane() -> PaneController? {
        guard let deskID = AppModel.shared.keyDeskID, let id = AppModel.shared.desks[deskID]?.focusedID else { return nil }
        return AppModel.shared.panes[id]
    }
}
