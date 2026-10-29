import AppKit

/// Theme names for the Appearance popup: built-ins, then any imported from the themes folder.
@MainActor
enum SettingsThemeSource {
    static var names: () -> [String] = { Themes.names() }
}

enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case appearance
    case terminal
    case windows
    case keys
    case cloud

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .windows: "Windows"
        case .keys: "Keys"
        case .cloud: "Cloud"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .terminal: "terminal"
        case .windows: "macwindow.on.rectangle"
        case .keys: "keyboard"
        case .cloud: "cloud"
        }
    }

    var identifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("aether.settings.\(rawValue)")
    }

    init?(identifier: NSToolbarItem.Identifier) {
        guard let tab = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = tab
    }
}

/// How Settings writes numbers for people: "24 %", "13 pt", "1.2×".
enum SettingsFormat {
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }

    static func points(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded)) pt" }
        return String(format: "%.1f pt", rounded)
    }

    static func multiplier(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        if hundredths % 10 == 0 { return String(format: "%.1f×", Double(hundredths) / 100) }
        return String(format: "%.2f×", Double(hundredths) / 100)
    }

    static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole >= 60, whole % 60 == 0 {
            let minutes = whole / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }

    static let unlimitedScrollback = 1_000_000
    static let scrollbackChoices = [1_000, 10_000, 100_000, unlimitedScrollback]
    static let notifyChoices: [Double] = [5, 10, 30, 60, 300]

    static func scrollback(_ lines: Int, locale: Locale = .current) -> String {
        if lines >= unlimitedScrollback { return "Unlimited" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        let number = formatter.string(from: NSNumber(value: lines)) ?? String(lines)
        return lines == 1 ? "1 line" : "\(number) lines"
    }

    /// The standard choices, plus the current value when config.json holds something else.
    static func choices<T: Comparable>(_ base: [T], including current: T) -> [T] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    static func snap(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return ((value / step).rounded() * step * 10_000).rounded() / 10_000
    }
}

extension Settings {
    /// Everything back to how Aether ships, except the Cloud account.
    func resetKeepingCloud() -> Settings {
        var fresh = Settings()
        fresh.sessionHost = sessionHost
        fresh.sessionToken = sessionToken
        fresh.sessionWS = sessionWS
        fresh.cloudEnabled = cloudEnabled
        return fresh
    }
}

/// Monospaced families for the Font popup. Hidden system families start with a dot.
@MainActor
enum SettingsFonts {
    private static var cached: [String]?

    static func monospacedFamilies() -> [String] {
        if let cached { return cached }
        let manager = NSFontManager.shared
        let fixed = NSFontTraitMask.fixedPitchFontMask.rawValue
        let families = manager.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), let members = manager.availableMembers(ofFontFamily: family) else { return false }
            return members.contains { member in
                guard member.count > 3, let traits = (member[3] as? NSNumber)?.uintValue else { return false }
                return traits & fixed != 0
            }
        }
        let sorted = families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        cached = sorted
        return sorted
    }
}

final class SettingsWindow: NSWindow {
    var onTab: ((Int) -> Void)?
    var onClose: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if held == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "w" {
                onClose?()
                return true
            }
            if let number = Int(key), (1...SettingsTab.allCases.count).contains(number) {
                onTab?(number - 1)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A slider with its value written out beside it.
@MainActor
private final class SliderField {
    let slider = NSSlider()
    let value = NSTextField(labelWithString: "")
    let view: NSStackView
    private let step: Double
    private let format: (Double) -> String

    init(_ name: String, min: Double, max: Double, step: Double, format: @escaping (Double) -> String) {
        self.step = step
        self.format = format
        slider.cell = GlassSliderCell()
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.altIncrementValue = step
        slider.setAccessibilityLabel(name)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.setAccessibilityElement(false)
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 64).isActive = true
        view = NSStackView(views: [slider, value])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 10
    }

    var doubleValue: Double {
        get { SettingsFormat.snap(slider.doubleValue, step: step) }
        set {
            slider.doubleValue = newValue
            paint()
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            value.textColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    func paint() {
        let text = format(doubleValue)
        value.stringValue = text
        slider.setAccessibilityValueDescription(text)
    }
}

/// Two columns: labels on the right edge of the first, controls in the second.
@MainActor
private final class SettingsForm {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var spaceNext = false

    init() {
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 176
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    @discardableResult
    func row(_ title: String, _ control: NSView, centered: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .right
        let titled = control is NSButton && !(control is NSPopUpButton)
        if !title.isEmpty, !titled, control.accessibilityLabel()?.isEmpty ?? true {
            control.setAccessibilityLabel(title.replacingOccurrences(of: ":", with: ""))
        }
        let added = grid.addRow(with: [label, control])
        if centered {
            added.rowAlignment = .none
            added.yPlacement = .center
        }
        if spaceNext {
            added.topPadding = 12
            spaceNext = false
        }
        return label
    }

    @discardableResult
    func note(_ text: String) -> NSTextField {
        let label = SettingsController.note(text)
        let added = grid.addRow(with: [NSGridCell.emptyContentView, label])
        added.topPadding = -4
        return label
    }

    @discardableResult
    func view(_ view: NSView) -> NSGridRow {
        let added = grid.addRow(with: [NSGridCell.emptyContentView, view])
        added.topPadding = -2
        return added
    }

    func section() {
        spaceNext = true
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One tab's content and the height it would like.
@MainActor
private final class SettingsPage {
    let view: NSView
    let preferredHeight: () -> CGFloat
    weak var firstResponder: NSView?

    init(view: NSView, preferredHeight: @escaping () -> CGFloat) {
        self.view = view
        self.preferredHeight = preferredHeight
    }

    static func scrolling(_ form: SettingsForm) -> SettingsPage {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(form.grid)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            form.grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            form.grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            form.grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24),
            form.grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        return SettingsPage(view: scroll) { [weak grid = form.grid] in
            (grid?.fittingSize.height ?? 300) + 46
        }
    }
}

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private static let tabKey = "aether.settings.tab"
    private static let keysHeightKey = "aether.settings.keysHeight"
    private static let width: CGFloat = 640

    private let glassView = NSGlassEffectView()
    private let pageHolder = NSView()
    /// "Some settings come from ~/.config/aether/config", above every tab while that file exists.
    private let configNote = NSTextField(labelWithString: "")
    private var pageTop: NSLayoutConstraint?
    private var pages: [SettingsTab: SettingsPage] = [:]
    private var current: SettingsTab = .general
    private let recorder = ShortcutRecorder()

    // General
    private let updates = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
    private let updateStatus = NSTextField(labelWithString: "")
    private let updateRing = UpdateRing(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let installUpdate = NSButton(title: "Restart to Update", target: nil, action: nil)
    private let versionLine = NSTextField(labelWithString: "")
    private let notify = NSButton(checkboxWithTitle: "Notify when a command finishes in the background", target: nil, action: nil)
    private let notifyAfter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let confirmClose = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dock = NSButton(checkboxWithTitle: "Hide the Dock icon", target: nil, action: nil)

    // Appearance
    private let toneOrder: [TextTone] = [.automatic, .light, .dark]
    private let glassOrder: [GlassStyle] = [.regular, .clear]
    private lazy var text = NSSegmentedControl(labels: toneOrder.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private lazy var glass = NSSegmentedControl(labels: glassOrder.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let shade = SliderField("Shade", min: 0, max: 0.82, step: 0.01, format: SettingsFormat.percent)
    private let theme = NSPopUpButton(frame: .zero, pullsDown: false)
    private let contrast = SliderField("Minimum contrast", min: 0, max: 1, step: 0.01, format: SettingsFormat.percent)
    private let fontFamily = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSize = SliderField("Text size", min: 10, max: 24, step: 0.5, format: SettingsFormat.points)
    private let lineHeight = SliderField("Line height", min: 0.8, max: 2, step: 0.05, format: SettingsFormat.multiplier)
    private let cursorShape = NSSegmentedControl(labels: CursorShape.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let cursorBlink = NSButton(checkboxWithTitle: "Blink", target: nil, action: nil)
    private let rest = NSSegmentedControl(labels: FocusRest.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let blur = SliderField("Blur amount", min: 0, max: 1, step: 0.01, format: SettingsFormat.percent)
    private var blurLabel: NSTextField?

    // Terminal
    private let optionKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shellExit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pasteWarning = NSButton(checkboxWithTitle: "Warn before pasting several lines", target: nil, action: nil)
    private let copyOnSelect = NSButton(checkboxWithTitle: "Copy text as soon as it's selected", target: nil, action: nil)
    private let gpuRendering = NSButton(checkboxWithTitle: "GPU rendering", target: nil, action: nil)
    private let bell = NSSegmentedControl(labels: BellStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let scrollback = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restoreContents = NSButton(checkboxWithTitle: "Restore terminal contents", target: nil, action: nil)

    // Windows
    private let radius = SliderField("Corner radius", min: 8, max: 32, step: 1, format: SettingsFormat.points)
    private let gap = SliderField("Gap", min: 2, max: 22, step: 1, format: SettingsFormat.points)
    private let snap = NSButton(checkboxWithTitle: "Snap windows into place when you let go", target: nil, action: nil)
    private let dropdown = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private lazy var dropdownKey = ShortcutButton(action: .dropdown, recorder: recorder)
    private let hotkeyTaken = NSTextField(labelWithString: "This shortcut is used by another app.")
    private let dropdownHeight = SliderField("Dropdown height", min: 0.2, max: 1, step: 0.01, format: SettingsFormat.percent)
    private let dropdownHide = NSButton(checkboxWithTitle: "Hide the dropdown when it loses focus", target: nil, action: nil)
    private let windowsNote = ShortcutNoteBar()
    private var hotkeyRow: NSGridRow?
    private var windowsNoteRow: NSGridRow?

    // Keys
    private let search = NSSearchField()
    private lazy var keybinds = KeybindBoard(recorder: recorder)
    private let keysNote = ShortcutNoteBar()

    // Cloud
    private let sessionWhere = NSSegmentedControl(labels: ["Local", "Cloud"], trackingMode: .selectOne, target: nil, action: nil)
    private let cloudStatus = NSTextField(wrappingLabelWithString: "")
    private var cloudChosen = false
    private let pairButton = NSButton(title: "Code for another device", target: nil, action: nil)
    private let signOutButton = NSButton(title: "Sign Out of Cloud…", target: nil, action: nil)

    private var prompting = false
    private var applying = false
    private var writing = false
    private var fitting = false

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: Self.width, height: 240)
        window.maxSize = NSSize(width: Self.width, height: 4000)
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        window.onClose = { [weak self] in self?.vaporize() }
        window.onTab = { [weak self] index in self?.select(SettingsTab.allCases[index], animate: true) }

        glassView.autoresizingMask = [.width, .height]
        glassView.frame = window.contentView?.bounds ?? .zero
        glassView.style = .regular
        glassView.enableInteractiveGlass()
        let host = NSView(frame: glassView.bounds)
        host.autoresizingMask = [.width, .height]
        glassView.contentView = host
        GlassPanel.mount(glassView, on: window, radius: 24)

        pageHolder.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pageHolder)
        configNote.font = .systemFont(ofSize: 12)
        configNote.textColor = .secondaryLabelColor
        configNote.alignment = .center
        configNote.isHidden = true
        configNote.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(configNote)
        let pageTop = pageHolder.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor)
        self.pageTop = pageTop
        NSLayoutConstraint.activate([
            pageHolder.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pageHolder.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pageTop,
            pageHolder.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            configNote.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            configNote.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            configNote.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])

        pages[.general] = generalPage()
        pages[.appearance] = appearancePage()
        pages[.terminal] = terminalPage()
        pages[.windows] = windowsPage()
        pages[.keys] = keysPage()
        pages[.cloud] = cloudPage()

        let toolbar = NSToolbar(identifier: "AetherSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        recorder.window = window
        recorder.observe { [weak self] in self?.recorderChanged() }

        wire()
        NotificationCenter.default.addObserver(forName: .aetherBindingsChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsChangedElsewhere()
            }
        }

        let saved = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
        select(saved, animate: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Pages

    private func generalPage() -> SettingsPage {
        let form = SettingsForm()
        form.row("Updates:", updates)
        checkNow.bezelStyle = .push
        checkNow.target = self
        checkNow.action = #selector(checkForUpdates)
        updateStatus.font = .systemFont(ofSize: 12)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.lineBreakMode = .byTruncatingTail
        installUpdate.bezelStyle = .push
        installUpdate.tintProminence = .primary
        installUpdate.target = self
        installUpdate.action = #selector(installUpdatePressed)
        installUpdate.isHidden = true
        updateRing.isHidden = true
        updateRing.widthAnchor.constraint(equalToConstant: 16).isActive = true
        updateRing.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let checkRow = NSStackView(views: [checkNow, updateRing, updateStatus, installUpdate])
        checkRow.orientation = .horizontal
        checkRow.alignment = .centerY
        checkRow.spacing = 10
        form.view(checkRow)
        versionLine.font = .systemFont(ofSize: 12)
        versionLine.textColor = .secondaryLabelColor
        versionLine.isSelectable = true
        form.view(versionLine)

        form.section()
        form.row("Notifications:", notify)
        notifyAfter.controlSize = .regular
        let after = NSStackView(views: [NSTextField(labelWithString: "when it ran longer than"), notifyAfter])
        after.orientation = .horizontal
        after.alignment = .firstBaseline
        after.spacing = 8
        notifyAfter.setAccessibilityLabel("Notify when a command ran longer than")
        form.view(after)

        form.section()
        confirmClose.addItems(withTitles: ConfirmClose.allCases.map(\.title))
        form.row("Confirm before closing:", confirmClose)
        form.row("Dock:", dock)
        form.note("Without the Dock icon, open Aether with the dropdown shortcut or from Spotlight.")

        form.section()
        let givePermissions = NSButton(title: "Give All Permissions…", target: self, action: #selector(giveAllPermissions))
        givePermissions.bezelStyle = .push
        form.row("Permissions:", givePermissions)
        form.note("Asks macOS for camera, microphone, folders, Accessibility, Full Disk Access, and the rest, one dialog at a time.")

        form.section()
        let reveal = NSButton(title: "Show config.json in Finder", target: self, action: #selector(revealConfig))
        reveal.bezelStyle = .push
        let reset = NSButton(title: "Reset All Settings…", target: self, action: #selector(resetAll))
        reset.bezelStyle = .push
        let buttons = NSStackView(views: [reveal, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        form.row("Configuration:", buttons, centered: true)
        return SettingsPage.scrolling(form)
    }

    private func appearancePage() -> SettingsPage {
        let form = SettingsForm()
        form.row("Text:", text)
        form.note("Automatic follows macOS: light text in Dark Mode, dark text in Light Mode.")
        form.row("Glass:", glass)
        form.note("Clear stays clear when you click away. Regular eases into frost.")
        form.row("Shade:", shade.view, centered: true)

        form.section()
        form.row("Theme:", theme)
        form.row("Minimum contrast:", contrast.view, centered: true)
        form.note("Raises colors that would be hard to read against the glass.")

        form.section()
        form.row("Font:", fontFamily)
        form.row("Text size:", fontSize.view, centered: true)
        form.row("Line height:", lineHeight.view, centered: true)
        let cursor = NSStackView(views: [cursorShape, cursorBlink])
        cursor.orientation = .horizontal
        cursor.alignment = .centerY
        cursor.spacing = 14
        cursorShape.setAccessibilityLabel("Cursor shape")
        cursorBlink.setAccessibilityLabel("Blink the cursor")
        form.row("Cursor:", cursor, centered: true)

        form.section()
        form.row("Unfocused panes:", rest)
        blurLabel = form.row("Blur amount:", blur.view, centered: true)
        form.note("Dim softens other panes. Blur frosts them by the amount above, with a short fade. Clear glass never frosts. As is leaves them alone.")
        return SettingsPage.scrolling(form)
    }

    private func terminalPage() -> SettingsPage {
        let form = SettingsForm()
        optionKey.addItems(withTitles: OptionKey.allCases.map(\.title))
        shellExit.addItems(withTitles: ShellExit.allCases.map(\.title))
        form.row("Option key:", optionKey)
        form.row("When the shell exits:", shellExit)
        form.note("A shell that exits cleanly closes its terminal. A command, or an error, keeps it open with Restart.")

        form.section()
        form.row("Paste:", pasteWarning)
        form.note("Only when the shell would run each line as it arrives.")
        form.row("Selection:", copyOnSelect)
        editor.addItems(withTitles: EditorChoice.allCases.map(\.title))
        form.row("Open files in:", editor)
        form.note("⌘-click a path in the output to open it at its line. Automatic uses $VISUAL or $EDITOR when it names an app like VS Code or Zed.")
        form.row("Bell:", bell)
        form.row("Scrollback:", scrollback)
        form.row("", restoreContents)
        form.note("Each terminal shows its old text again after Aether restarts. ⌘K forgets it.")
        form.row("Drawing:", gpuRendering)
        form.note("Draws text with Metal instead of CoreGraphics. Experimental: it is not faster yet and uses a little more CPU.")
        form.section()
        form.note("macOS asks once for Local Network access. Allow it if you want arp, mDNS, and other LAN commands to show real devices.")
        return SettingsPage.scrolling(form)
    }

    private func windowsPage() -> SettingsPage {
        let form = SettingsForm()
        form.row("Corner radius:", radius.view, centered: true)
        form.row("Gap:", gap.view, centered: true)
        form.row("Snapping:", snap)

        form.section()
        let line = NSStackView(views: [dropdown, dropdownKey])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        dropdown.setAccessibilityLabel("Dropdown terminal")
        form.row("Dropdown terminal:", line, centered: true)
        hotkeyTaken.font = .systemFont(ofSize: 12)
        hotkeyTaken.textColor = .systemOrange
        hotkeyRow = form.view(hotkeyTaken)
        windowsNote.onUndo = { [weak self] in self?.recorder.undo() }
        windowsNoteRow = form.view(windowsNote)
        windowsNoteRow?.isHidden = true
        form.row("Height:", dropdownHeight.view, centered: true)
        form.row("", dropdownHide)
        return SettingsPage.scrolling(form)
    }

    private func keysPage() -> SettingsPage {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search shortcuts"
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search shortcuts")
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .push
        restore.toolTip = "Put every shortcut back the way Aether ships"
        let top = NSStackView(views: [search, restore])
        top.orientation = .horizontal
        top.spacing = 10
        top.translatesAutoresizingMaskIntoConstraints = false
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let help = Self.note("Click a shortcut, then press the new keys. Delete removes it. Esc cancels.")
        help.translatesAutoresizingMaskIntoConstraints = false
        keysNote.onUndo = { [weak self] in self?.recorder.undo() }
        keysNote.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        keybinds.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = keybinds

        let column = NSStackView(views: [top, help, keysNote, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -16),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            keybinds.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            keybinds.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            keybinds.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let result = SettingsPage(view: page) {
            let saved = UserDefaults.standard.double(forKey: Self.keysHeightKey)
            return saved > 0 ? saved : 560
        }
        result.firstResponder = search
        return result
    }

    private func cloudPage() -> SettingsPage {
        let form = SettingsForm()
        form.row("New terminals run:", sessionWhere)
        cloudStatus.font = .systemFont(ofSize: 12)
        cloudStatus.textColor = .secondaryLabelColor
        cloudStatus.preferredMaxLayoutWidth = 380
        form.view(cloudStatus)
        form.note("Cloud gives you a terminal of your own. The shell stays up after you quit. The code opens it on a phone or another computer. Local keeps your Cloud account for later.")

        form.section()
        pairButton.target = self
        pairButton.action = #selector(pairDevice)
        pairButton.bezelStyle = .push
        signOutButton.target = self
        signOutButton.action = #selector(signOut)
        signOutButton.bezelStyle = .push
        form.row("Devices:", pairButton, centered: true)
        form.row("Account:", signOutButton, centered: true)
        return SettingsPage.scrolling(form)
    }

    private func wire() {
        for control in [text, glass, rest, cursorShape, bell] {
            control.target = self
            control.action = #selector(changed)
        }
        sessionWhere.target = self
        sessionWhere.action = #selector(changed)
        sessionWhere.segmentDistribution = .fillEqually
        for popup in [notifyAfter, confirmClose, theme, fontFamily, optionKey, shellExit, scrollback, editor] {
            popup.target = self
            popup.action = #selector(changed)
        }
        for box in [updates, notify, dock, cursorBlink, pasteWarning, copyOnSelect, restoreContents, snap, dropdown, dropdownHide, gpuRendering] {
            box.target = self
            box.action = #selector(changed)
        }
        for field in [shade, contrast, fontSize, lineHeight, blur, radius, gap, dropdownHeight] {
            field.slider.target = self
            field.slider.action = #selector(changed)
        }
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 380
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    // MARK: Tabs

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(identifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        let index = (SettingsTab.allCases.firstIndex(of: tab) ?? 0) + 1
        item.toolTip = "\(tab.title) (⌘\(index))"
        item.target = self
        item.action = #selector(toolbarPicked(_:))
        return item
    }

    @objc private func toolbarPicked(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(identifier: sender.itemIdentifier) else { return }
        select(tab, animate: true)
    }

    private func select(_ tab: SettingsTab, animate: Bool) {
        guard let window, let page = pages[tab] else { return }
        let changing = tab != current || page.view.superview == nil
        if tab != current {
            recorder.stop()
            recorder.clearNote()
        }
        current = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        window.toolbar?.selectedItemIdentifier = tab.identifier
        window.title = tab.title
        guard changing else { return }
        pageHolder.subviews.forEach { $0.removeFromSuperview() }
        let view = page.view
        view.translatesAutoresizingMaskIntoConstraints = false
        pageHolder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: pageHolder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageHolder.trailingAnchor),
            view.topAnchor.constraint(equalTo: pageHolder.topAnchor),
            view.bottomAnchor.constraint(equalTo: pageHolder.bottomAnchor),
        ])
        let motion = animate && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if motion {
            view.alphaValue = 0
            Motion.group(Motion.close) { view.animator().alphaValue = 1 }
        } else {
            view.alphaValue = 1
        }
        fit(animate: motion)
        if window.isVisible {
            window.makeFirstResponder(page.firstResponder ?? window.contentView)
        }
    }

    /// Each tab gets the height it needs, kept on screen. Keys keeps whatever height it was dragged to.
    private func fit(animate: Bool) {
        guard let window, let page = pages[current] else { return }
        pageHolder.layoutSubtreeIfNeeded()
        page.view.layoutSubtreeIfNeeded()
        let chrome = window.frame.height - window.contentLayoutRect.height
        var height = page.preferredHeight() + chrome + (pageTop?.constant ?? 0)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            height = min(height, screen.height - 40)
        }
        height = max(height, window.minSize.height)
        var frame = window.frame
        guard abs(frame.height - height) > 0.5 || frame.width != Self.width else { return }
        frame.origin.y = frame.maxY - height
        frame.size = NSSize(width: Self.width, height: height)
        fitting = true
        window.setFrame(frame, display: true, animate: animate)
        fitting = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard current == .keys, !fitting, let window else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        UserDefaults.standard.set(window.frame.height - chrome, forKey: Self.keysHeightKey)
    }

    // MARK: Showing

    func show() {
        load()
        UpdateCenter.shared.onStatus = { [weak self] message in
            self?.updateStatus.stringValue = message
        }
        UpdateCenter.shared.onStage = { [weak self] stage in
            self?.showUpdate(stage)
        }
        if let stage = UpdateCenter.shared.lastStage { showUpdate(stage) }
        SessionHub.shared.onLink = { [weak self] link in
            self?.cloudStatus.stringValue = link.title
            self?.cloudStatus.textColor = {
                switch link {
                case .failed, .unavailable: return .systemRed
                default: return .secondaryLabelColor
                }
            }()
        }
        cloudStatus.stringValue = SessionHub.shared.link.title
        if cloudChosen {
            switch SessionHub.shared.link {
            case .idle, .unavailable:
                Task { await self.connectCloud() }
            default:
                break
            }
        }
        guard let window else { return }
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.toolbar?.selectedItemIdentifier = current.identifier
        fit(animate: false)
        window.center()
        GlassMotion.present(window)
        window.makeFirstResponder(pages[current]?.firstResponder ?? window.contentView)
    }

    /// Closes Settings. The name stays because the menus call it for ⌘W.
    func vaporize() {
        recorder.stop()
        recorder.clearNote()
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        window.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        recorder.stop()
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stop()
        recorder.clearNote()
    }

    private func settingsChangedElsewhere() {
        guard !writing, window?.isVisible == true else { return }
        load()
    }

    private func recorderChanged() {
        let note = recorder.note
        keysNote.show(note)
        windowsNote.show(current == .windows ? note : nil)
        windowsNoteRow?.isHidden = windowsNote.isHidden
        paintDropdownKey()
        if current == .keys, window?.isVisible == true {
            keysNote.superview?.layoutSubtreeIfNeeded()
        }
    }

    private func paintDropdownKey() {
        let settings = AppModel.shared.settings
        dropdownKey.refresh(settings.keys.chord(.dropdown), recording: recorder.recording == .dropdown)
        hotkeyRow?.isHidden = !(settings.dropdownEnabled && HotkeyCenter.takenByAnotherApp)
    }

    // MARK: Writing

    @objc private func changed() {
        guard !applying else { return }
        let wantsCloud = sessionWhere.selectedSegment == 1
        let switched = wantsCloud != cloudChosen && !prompting
        let wasNotifying = AppModel.shared.settings.notifyOnFinish
        writing = true
        AppModel.shared.updateSettings { settings in
            settings.checkForUpdates = updates.state == .on
            settings.notifyOnFinish = notify.state == .on
            if let seconds = notifyAfter.selectedItem?.representedObject as? Double {
                settings.notifyAfterSeconds = seconds
            }
            settings.confirmClose = ConfirmClose.allCases[max(0, confirmClose.indexOfSelectedItem)]
            settings.hideDockIcon = dock.state == .on

            settings.text = toneOrder[max(0, text.selectedSegment)]
            settings.glass = glassOrder[max(0, glass.selectedSegment)]
            settings.shade = shade.doubleValue
            if let name = theme.titleOfSelectedItem {
                settings.themeName = name
            }
            settings.minimumContrast = contrast.doubleValue
            if let family = fontFamily.selectedItem?.representedObject as? String {
                settings.fontFamily = family
            }
            if abs(settings.fontSize - fontSize.doubleValue) > 0.01 {
                settings.fontSize = fontSize.doubleValue
                settings.baseFontSize = fontSize.doubleValue
            }
            settings.lineHeight = lineHeight.doubleValue
            settings.cursorShape = CursorShape.allCases[max(0, cursorShape.selectedSegment)]
            settings.cursorBlink = cursorBlink.state == .on
            settings.focusRest = FocusRest.allCases[max(0, rest.selectedSegment)]
            settings.blurAmount = blur.doubleValue

            settings.optionKey = OptionKey.allCases[max(0, optionKey.indexOfSelectedItem)]
            settings.shellExit = ShellExit.allCases[max(0, shellExit.indexOfSelectedItem)]
            settings.warnMultilinePaste = pasteWarning.state == .on
            settings.copyOnSelect = copyOnSelect.state == .on
            settings.restoreContents = restoreContents.state == .on
            settings.gpuRendering = gpuRendering.state == .on
            settings.editor = EditorChoice.allCases[max(0, editor.indexOfSelectedItem)]
            settings.bell = BellStyle.allCases[max(0, bell.selectedSegment)]
            if let lines = scrollback.selectedItem?.representedObject as? Int {
                settings.scrollbackLines = lines
            }

            settings.cornerRadius = radius.doubleValue
            settings.gap = gap.doubleValue
            settings.snapWindows = snap.state == .on
            settings.dropdownEnabled = dropdown.state == .on
            settings.dropdownHeight = dropdownHeight.doubleValue
            settings.dropdownHideOnFocusLoss = dropdownHide.state == .on

            if switched && !wantsCloud {
                // Local stops using the account. It does not forget it.
                settings.cloudEnabled = false
            }
        }
        writing = false
        paintValues()
        enableDependents()
        glassView.style = AppModel.shared.settings.glass == .clear ? .clear : .regular
        if !wasNotifying, AppModel.shared.settings.notifyOnFinish {
            FinishNotifier.requestPermission()
        }
        paintDropdownKey()
        guard switched else { return }
        if wantsCloud {
            Task { await self.chooseCloud() }
        } else {
            cloudChosen = false
            SessionHub.shared.setLink(.idle)
            refreshCloudControls()
        }
    }

    @objc private func searchChanged() {
        keybinds.filter(search.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if search.stringValue.isEmpty {
            vaporize()
        } else {
            search.stringValue = ""
            searchChanged()
        }
        return true
    }

    @objc private func restoreDefaults() {
        recorder.restoreAll()
    }

    @objc private func resetAll() {
        Task {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Reset all settings?"
            alert.informativeText = "Look, terminal, window, and shortcut settings go back to how Aether ships. Your Cloud account stays."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Reset")
            guard await confirm(alert) == .alertSecondButtonReturn else { return }
            recorder.stop()
            recorder.clearNote()
            AppModel.shared.updateSettings { settings in
                settings = settings.resetKeepingCloud()
            }
            load()
        }
    }

    // MARK: Cloud

    private func chooseCloud() async {
        if !AppModel.shared.settings.hasCloudAccount {
            let alert = NSAlert()
            alert.messageText = "Start a Cloud account?"
            alert.informativeText = "Aether will make a Cloud account for this Mac. New terminals will run on the Cloud server instead of this Mac."
            alert.addButton(withTitle: "Start Cloud")
            alert.addButton(withTitle: "Cancel")
            guard await confirm(alert) == .alertFirstButtonReturn else {
                showLocal()
                return
            }
            SessionHub.shared.setLink(.connecting)
            do {
                try await SessionHub.shared.enroll()
            } catch {
                SessionHub.shared.setLink(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                showLocal()
                return
            }
        }
        cloudChosen = true
        writing = true
        AppModel.shared.updateSettings { $0.cloudEnabled = true }
        writing = false
        refreshCloudControls()
        await connectCloud()
    }

    private func showLocal() {
        applying = true
        sessionWhere.selectedSegment = 0
        applying = false
        cloudChosen = false
        refreshCloudControls()
    }

    private func connectCloud() async {
        guard AppModel.shared.settings.usesCloud else { return }
        SessionHub.shared.setLink(.connecting)
        do {
            try await SessionHub.shared.open()
        } catch SessionError.unauthorized {
            // SessionHub asks the person what to do.
        } catch {
            SessionHub.shared.setLink(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private func confirm(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        prompting = true
        defer { prompting = false }
        guard let window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
        }
    }

    private func refreshCloudControls() {
        let settings = AppModel.shared.settings
        pairButton.isEnabled = settings.usesCloud
        signOutButton.isEnabled = settings.hasCloudAccount
    }

    @objc private func signOut() {
        Task {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Sign out of Cloud?"
            alert.informativeText = "This Mac forgets its Cloud account and goes back to Local. Terminals running in Cloud can't be reached from here again. The sign-in is kept in your keychain as a backup."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Sign Out")
            guard await confirm(alert) == .alertSecondButtonReturn else { return }
            SessionHub.shared.signOut()
            load()
        }
    }

    @objc private func pairDevice() {
        let settings = AppModel.shared.settings
        guard settings.usesCloud else { return }
        cloudStatus.stringValue = "Making a code…"
        Task {
            do {
                let result = try await CloudCatalog.pair(token: settings.sessionToken, ws: settings.sessionWS)
                if !result.url.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.url, forType: .string)
                    cloudStatus.stringValue = "Code \(result.code). The link is on the clipboard."
                } else {
                    cloudStatus.stringValue = "Code \(result.code)"
                }
            } catch {
                cloudStatus.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: General actions

    private var updatesOff: Bool {
        System.isDev || !BuildStamp.current.isRelease
    }

    @objc private func checkForUpdates() {
        updateStatus.stringValue = "Checking…"
        Task {
            // The answer arrives through onStatus and onStage, with the time it was checked.
            _ = await UpdateCenter.shared.checkNow(card: false)
        }
    }

    @objc private func installUpdatePressed() {
        UpdateCenter.shared.installNow()
    }

    /// The same ring and words as the update card, in one line.
    private func showUpdate(_ stage: UpdateStage) {
        updateRing.isHidden = false
        updateRing.show(stage)
        updateStatus.stringValue = stage.summary
        if case .ready = stage { installUpdate.isHidden = false } else { installUpdate.isHidden = true }
    }

    @objc private func revealConfig() {
        ConfigStore.save(AppModel.shared.settings)
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL()])
    }

    @objc private func giveAllPermissions() {
        PermissionGrant.present(from: window)
    }

    // MARK: Reading

    private func load() {
        applying = true
        defer { applying = false }
        let settings = AppModel.shared.settings

        updates.state = settings.checkForUpdates ? .on : .off
        updates.isEnabled = !updatesOff
        checkNow.isEnabled = !updatesOff
        let stamp = BuildStamp.current
        if updatesOff {
            updateStatus.stringValue = UpdateCenter.devBuild
            versionLine.stringValue = stamp.version.isEmpty ? "Aether, development build" : "Aether \(stamp.version), development build"
        } else {
            versionLine.stringValue = "Aether \(stamp.version) (\(stamp.shortCommit))"
        }
        notify.state = settings.notifyOnFinish ? .on : .off
        fill(notifyAfter, SettingsFormat.choices(SettingsFormat.notifyChoices, including: settings.notifyAfterSeconds), current: settings.notifyAfterSeconds, title: SettingsFormat.duration)
        confirmClose.selectItem(at: ConfirmClose.allCases.firstIndex(of: settings.confirmClose) ?? 0)
        dock.state = settings.hideDockIcon ? .on : .off

        text.selectedSegment = toneOrder.firstIndex(of: settings.text) ?? 0
        glass.selectedSegment = glassOrder.firstIndex(of: settings.glass) ?? 0
        shade.doubleValue = settings.shade
        loadThemes(settings.themeName)
        contrast.doubleValue = settings.minimumContrast
        loadFonts(settings.fontFamily)
        fontSize.doubleValue = settings.fontSize
        lineHeight.doubleValue = settings.lineHeight
        cursorShape.selectedSegment = CursorShape.allCases.firstIndex(of: settings.cursorShape) ?? 0
        cursorBlink.state = settings.cursorBlink ? .on : .off
        rest.selectedSegment = FocusRest.allCases.firstIndex(of: settings.focusRest) ?? 0
        blur.doubleValue = settings.blurAmount

        optionKey.selectItem(at: OptionKey.allCases.firstIndex(of: settings.optionKey) ?? 0)
        shellExit.selectItem(at: ShellExit.allCases.firstIndex(of: settings.shellExit) ?? 0)
        pasteWarning.state = settings.warnMultilinePaste ? .on : .off
        copyOnSelect.state = settings.copyOnSelect ? .on : .off
        restoreContents.state = settings.restoreContents ? .on : .off
        gpuRendering.state = settings.gpuRendering ? .on : .off
        editor.selectItem(at: EditorChoice.allCases.firstIndex(of: settings.editor) ?? 0)
        bell.selectedSegment = BellStyle.allCases.firstIndex(of: settings.bell) ?? 0
        let lines = settings.scrollbackLines
        fill(scrollback, SettingsFormat.choices(SettingsFormat.scrollbackChoices, including: lines), current: lines) { SettingsFormat.scrollback($0) }

        radius.doubleValue = settings.cornerRadius
        gap.doubleValue = settings.gap
        snap.state = settings.snapWindows ? .on : .off
        dropdown.state = settings.dropdownEnabled ? .on : .off
        dropdownHeight.doubleValue = settings.dropdownHeight
        dropdownHide.state = settings.dropdownHideOnFocusLoss ? .on : .off
        paintDropdownKey()

        if !prompting {
            sessionWhere.selectedSegment = settings.usesCloud ? 1 : 0
            cloudChosen = sessionWhere.selectedSegment == 1
        }
        refreshCloudControls()
        keybinds.reload()
        glassView.style = settings.glass == .clear ? .clear : .regular
        paintValues()
        for (_, controls) in configControls {
            for control in controls {
                // Updates stays off in development builds. load() set it above.
                if control !== updates { control.isEnabled = true }
                control.toolTip = control is ShortcutButton ? ShortcutButton.hint : nil
            }
        }
        enableDependents()
        let active = UserConfigCenter.shared.active
        configNote.stringValue = "Some settings come from \(UserConfigCenter.displayPath)"
        if configNote.isHidden == active {
            configNote.isHidden = !active
            pageTop?.constant = active ? 30 : 0
            if window?.isVisible == true { fit(animate: false) }
        }
    }

    /// The controls each config file key sets. They grey out while the file holds that key.
    private var configControls: [String: [NSControl]] {
        [
            "theme": [theme], "font-family": [fontFamily], "font-size": [fontSize.slider], "line-height": [lineHeight.slider],
            "glass": [glass], "text-tone": [text], "shade": [shade.slider], "minimum-contrast": [contrast.slider],
            "cursor-shape": [cursorShape], "cursor-blink": [cursorBlink], "unfocused-panes": [rest], "blur-amount": [blur.slider],
            "corner-radius": [radius.slider], "gap": [gap.slider], "snap-windows": [snap],
            "option-as-meta": [optionKey], "shell-exit": [shellExit], "warn-multiline-paste": [pasteWarning],
            "copy-on-select": [copyOnSelect], "restore-contents": [restoreContents], "gpu-rendering": [gpuRendering], "editor": [editor], "bell": [bell], "scrollback": [scrollback],
            "notify-on-finish": [notify], "notify-after": [notifyAfter], "confirm-close": [confirmClose],
            "hide-dock-icon": [dock], "check-for-updates": [updates], "dropdown": [dropdown],
            "dropdown-height": [dropdownHeight.slider], "dropdown-hide-on-focus-loss": [dropdownHide],
            "keybind:dropdown": [dropdownKey],
        ]
    }

    private func lockConfigured() {
        let sources = UserConfigCenter.shared.config.sources
        for (key, controls) in configControls {
            guard let line = sources[key] else { continue }
            for control in controls {
                control.isEnabled = false
                control.toolTip = UserConfigCenter.lockNote(line: line)
            }
        }
    }

    private func fill<T: Equatable>(_ popup: NSPopUpButton, _ values: [T], current: T, title: (T) -> String) {
        popup.removeAllItems()
        for value in values {
            popup.addItem(withTitle: title(value))
            popup.lastItem?.representedObject = value
        }
        if let index = values.firstIndex(of: current) {
            popup.selectItem(at: index)
        }
    }

    private func loadThemes(_ selected: String) {
        var names = SettingsThemeSource.names()
        if !names.contains(selected) { names.append(selected) }
        theme.removeAllItems()
        theme.addItems(withTitles: names)
        theme.selectItem(withTitle: selected)
    }

    private func loadFonts(_ selected: String) {
        var families = SettingsFonts.monospacedFamilies()
        if !selected.isEmpty, !families.contains(selected) { families.insert(selected, at: 0) }
        fontFamily.removeAllItems()
        fontFamily.addItem(withTitle: "SF Mono (default)")
        fontFamily.lastItem?.representedObject = ""
        fontFamily.menu?.addItem(.separator())
        for family in families {
            fontFamily.addItem(withTitle: family)
            fontFamily.lastItem?.representedObject = family
            if let font = NSFont(name: family, size: 13) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                fontFamily.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        if selected.isEmpty {
            fontFamily.selectItem(at: 0)
        } else if let index = fontFamily.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            fontFamily.selectItem(at: index)
        }
    }

    private func paintValues() {
        for field in [shade, contrast, fontSize, lineHeight, blur, radius, gap, dropdownHeight] {
            field.paint()
        }
    }

    private func enableDependents() {
        let blurring = FocusRest.allCases[max(0, rest.selectedSegment)] == .blur
        blur.isEnabled = blurring
        blurLabel?.textColor = blurring ? .labelColor : .tertiaryLabelColor
        notifyAfter.isEnabled = notify.state == .on
        let dropping = dropdown.state == .on
        dropdownKey.isEnabled = dropping
        dropdownHeight.isEnabled = dropping
        dropdownHide.isEnabled = dropping
        lockConfigured()
    }
}

private final class GlassSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        let ink = NSColor.labelColor.withAlphaComponent(isEnabled ? 1 : 0.4)
        ink.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let span = max(maxValue - minValue, 0.0001)
        let t = CGFloat((doubleValue - minValue) / span)
        let fill = NSRect(x: rect.minX, y: track.minY, width: max(4, rect.width * t), height: 4)
        ink.withAlphaComponent(isEnabled ? 0.82 : 0.3).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let knob = NSRect(x: knobRect.midX - 7, y: knobRect.midY - 7, width: 14, height: 14)
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.94 : 0.35).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        if showsFirstResponder, let view = controlView, view.window?.firstResponder === view {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(ovalIn: knob.insetBy(dx: -2, dy: -2))
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}
