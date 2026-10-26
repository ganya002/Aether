import AppKit
import Carbon.HIToolbox

public struct KeyChord: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: UInt
    public var keyCode: UInt16
    public var follow: String?

    public init(key: String, modifiers: UInt, keyCode: UInt16, follow: String? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.follow = follow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        modifiers = try container.decode(UInt.self, forKey: .modifiers)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        follow = try container.decodeIfPresent(String.self, forKey: .follow)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encodeIfPresent(follow, forKey: .follow)
    }

    private enum CodingKeys: String, CodingKey {
        case key, modifiers, keyCode, follow
    }

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask)
    }

    var symbol: String {
        var text = ""
        let flags = self.flags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += Self.pretty(key)
        return key.isEmpty ? "None" : text
    }

    static func pretty(_ key: String) -> String {
        switch key {
        case "\r": return "↩"
        case "\t": return "⇥"
        case " ": return "Space"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        default:
            if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
               scalar.value >= UInt32(NSF1FunctionKey), scalar.value <= UInt32(NSF12FunctionKey) {
                return "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
            }
            return key.count == 1 ? key.uppercased() : key
        }
    }

    /// A shortcut needs Command, Option, or Control, so a plain letter still reaches the shell.
    static func capture(_ event: NSEvent) -> KeyChord? {
        if event.keyCode == 53 { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let bare = flags.intersection([.command, .option, .control, .shift])
        guard bare.contains(.command) || bare.contains(.control) || bare.contains(.option) else { return nil }
        let key = equivalent(event)
        guard !key.isEmpty else { return nil }
        return KeyChord(key: key, modifiers: bare.rawValue, keyCode: event.keyCode)
    }

    static func equivalent(_ event: NSEvent) -> String {
        if let special = event.specialKey {
            switch special {
            case .leftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .rightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .upArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .downArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .carriageReturn, .newline: return "\r"
            case .tab: return "\t"
            case .delete, .backspace: return String(UnicodeScalar(NSBackspaceCharacter)!)
            default: break
            }
        }
        let raw = event.charactersIgnoringModifiers ?? ""
        if raw.count == 1, let character = raw.first, character.isLetter {
            return String(character).lowercased()
        }
        return raw
    }

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        let flags = self.flags
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}

public enum AppAction: String, CaseIterable, Codable, Sendable {
    case newWindow
    case newPane
    case splitRight
    case splitDown
    case closePane
    case closeWindow
    case launch
    case clearBuffer
    case fill
    case equalize
    case nextLayout
    case previousLayout
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case growLeft
    case growRight
    case growUp
    case growDown
    case broadcast
    case fontUp
    case fontDown
    case fontReset
    case find
    case findNext
    case findPrevious
    case copy
    case paste
    case selectAll
    case settings
    case dropdown
    case quit
    case insertPath
    case focusPane1
    case focusPane2
    case focusPane3
    case focusPane4
    case focusPane5
    case focusPane6
    case focusPane7
    case focusPane8
    case focusPane9
    case previousPane
    case nextPane
    case swapNext
    case movePaneToWindow
    case renamePane
    case restartPane
    case shortcuts

    /// 1 through 9 for the Focus Terminal actions.
    var paneNumber: Int? {
        switch self {
        case .focusPane1: 1
        case .focusPane2: 2
        case .focusPane3: 3
        case .focusPane4: 4
        case .focusPane5: 5
        case .focusPane6: 6
        case .focusPane7: 7
        case .focusPane8: 8
        case .focusPane9: 9
        default: nil
        }
    }

    static func focusPane(_ number: Int) -> AppAction? {
        allCases.first { $0.paneNumber == number }
    }

    var title: String {
        switch self {
        case .newWindow: "New window"
        case .newPane: "New terminal"
        case .splitRight: "Split right"
        case .splitDown: "Split down"
        case .closePane: "Close terminal"
        case .closeWindow: "Close window"
        case .launch: "Launch"
        case .clearBuffer: "Clear scrollback"
        case .fill: "Fill window"
        case .equalize: "Equalize splits"
        case .nextLayout: "Next layout"
        case .previousLayout: "Previous layout"
        case .focusLeft: "Focus left"
        case .focusRight: "Focus right"
        case .focusUp: "Focus up"
        case .focusDown: "Focus down"
        case .growLeft: "Grow left"
        case .growRight: "Grow right"
        case .growUp: "Grow up"
        case .growDown: "Grow down"
        case .broadcast: "Broadcast keys"
        case .fontUp: "Bigger text"
        case .fontDown: "Smaller text"
        case .fontReset: "Actual size"
        case .find: "Find"
        case .findNext: "Find next"
        case .findPrevious: "Find previous"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select all"
        case .settings: "Settings"
        case .dropdown: "Dropdown terminal"
        case .quit: "Quit Aether"
        case .insertPath: "Insert a path"
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            "Focus terminal \(paneNumber ?? 0)"
        case .previousPane: "Previous terminal"
        case .nextPane: "Next terminal"
        case .swapNext: "Swap with next terminal"
        case .movePaneToWindow: "Move terminal to new window"
        case .renamePane: "Rename terminal"
        case .restartPane: "Restart terminal"
        case .shortcuts: "Keyboard shortcuts"
        }
    }

    /// Menu shortcuts that are fixed by macOS conventions and cannot be rebound.
    static let reservedChords: [KeyChord] = {
        func chord(_ key: String, _ flags: NSEvent.ModifierFlags) -> KeyChord {
            KeyChord(key: key, modifiers: flags.rawValue, keyCode: 0)
        }
        return [
            chord("h", .command),
            chord("h", [.command, .option]),
            chord("m", .command),
            chord("z", .command),
            chord("z", [.command, .shift]),
            chord("x", .command),
            chord("e", .command),
            chord("f", [.command, .control]),
        ]
    }()

    var defaultChord: KeyChord {
        func chord(_ key: String, _ flags: NSEvent.ModifierFlags, _ code: Int) -> KeyChord {
            KeyChord(key: key, modifiers: flags.rawValue, keyCode: UInt16(code))
        }
        let command = NSEvent.ModifierFlags.command
        switch self {
        case .newWindow: return chord("n", command, kVK_ANSI_N)
        case .newPane: return chord("t", command, kVK_ANSI_T)
        case .splitRight: return chord("d", command, kVK_ANSI_D)
        case .splitDown: return chord("d", [command, .shift], kVK_ANSI_D)
        case .closePane: return chord("w", command, kVK_ANSI_W)
        case .closeWindow: return chord("w", [command, .shift], kVK_ANSI_W)
        case .launch: return chord("p", command, kVK_ANSI_P)
        case .clearBuffer: return chord("k", command, kVK_ANSI_K)
        case .fill: return chord("\r", command, kVK_Return)
        case .equalize: return chord("e", [command, .shift], kVK_ANSI_E)
        case .nextLayout: return chord("l", [command, .shift], kVK_ANSI_L)
        case .previousLayout: return chord("l", [command, .option, .shift], kVK_ANSI_L)
        case .focusLeft: return chord(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [command, .option], kVK_LeftArrow)
        case .focusRight: return chord(String(UnicodeScalar(NSRightArrowFunctionKey)!), [command, .option], kVK_RightArrow)
        case .focusUp: return chord(String(UnicodeScalar(NSUpArrowFunctionKey)!), [command, .option], kVK_UpArrow)
        case .focusDown: return chord(String(UnicodeScalar(NSDownArrowFunctionKey)!), [command, .option], kVK_DownArrow)
        case .growLeft: return chord(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [command, .shift], kVK_LeftArrow)
        case .growRight: return chord(String(UnicodeScalar(NSRightArrowFunctionKey)!), [command, .shift], kVK_RightArrow)
        case .growUp: return chord(String(UnicodeScalar(NSUpArrowFunctionKey)!), [command, .shift], kVK_UpArrow)
        case .growDown: return chord(String(UnicodeScalar(NSDownArrowFunctionKey)!), [command, .shift], kVK_DownArrow)
        case .broadcast: return chord("b", command, kVK_ANSI_B)
        case .fontUp: return chord("=", command, kVK_ANSI_Equal)
        case .fontDown: return chord("-", command, kVK_ANSI_Minus)
        case .fontReset: return chord("0", command, kVK_ANSI_0)
        case .find: return chord("f", command, kVK_ANSI_F)
        case .findNext: return chord("g", command, kVK_ANSI_G)
        case .findPrevious: return chord("g", [command, .shift], kVK_ANSI_G)
        case .copy: return chord("c", command, kVK_ANSI_C)
        case .paste: return chord("v", command, kVK_ANSI_V)
        case .selectAll: return chord("a", command, kVK_ANSI_A)
        case .settings: return chord(",", command, kVK_ANSI_Comma)
        case .dropdown: return chord("`", [command, .control], kVK_ANSI_Grave)
        case .quit: return chord("q", command, kVK_ANSI_Q)
        case .insertPath: return chord("p", [command, .shift], kVK_ANSI_P)
        case .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9:
            let number = paneNumber ?? 1
            let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            return chord("\(number)", command, codes[number - 1])
        case .previousPane: return chord("[", command, kVK_ANSI_LeftBracket)
        case .nextPane: return chord("]", command, kVK_ANSI_RightBracket)
        case .swapNext: return chord("]", [command, .option], kVK_ANSI_RightBracket)
        case .movePaneToWindow: return chord("n", [command, .option], kVK_ANSI_N)
        case .renamePane: return chord("i", [command, .shift], kVK_ANSI_I)
        case .restartPane: return KeyChord(key: "", modifiers: 0, keyCode: 0)
        case .shortcuts: return chord("/", command, kVK_ANSI_Slash)
        }
    }
}

public struct KeyMap: Codable, Equatable, Sendable {
    public var chords: [String: KeyChord]

    public init(chords: [String: KeyChord]) {
        self.chords = chords
    }

    /// A chord that fails to decode is dropped on its own. `filled()` puts the default back.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var chords: [String: KeyChord] = [:]
        if let nested = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .chords) {
            for key in nested.allKeys {
                if let chord = try? nested.decode(KeyChord.self, forKey: key) {
                    chords[key.stringValue] = chord
                }
            }
        }
        self.chords = chords
    }

    private enum CodingKeys: String, CodingKey {
        case chords
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public static var standard: KeyMap {
        KeyMap(chords: Dictionary(uniqueKeysWithValues: AppAction.allCases.map { ($0.rawValue, $0.defaultChord) }))
    }

    func chord(_ action: AppAction) -> KeyChord {
        chords[action.rawValue] ?? action.defaultChord
    }

    func symbol(_ action: AppAction) -> String {
        chord(action).symbol
    }

    func filled() -> KeyMap {
        var next = self.movingLauncherOffCommandK()
        for action in AppAction.allCases where next.chords[action.rawValue] == nil {
            let chord = action.defaultChord
            let taken = next.chords.contains { $0.key != action.rawValue && $0.value.key == chord.key && $0.value.modifiers == chord.modifiers }
            next.chords[action.rawValue] = taken ? KeyChord(key: "", modifiers: 0, keyCode: 0) : chord
        }
        // The old default stored "+" for the equals key. Menus match "=" for Command-equals, so "+" never fired.
        let command = NSEvent.ModifierFlags.command.rawValue
        if var bigger = next.chords[AppAction.fontUp.rawValue],
           bigger.key == "+",
           bigger.keyCode == UInt16(kVK_ANSI_Equal),
           bigger.modifiers == command {
            bigger.key = "="
            next.chords[AppAction.fontUp.rawValue] = bigger
        }
        return next
    }

    /// ⌘K used to open the launcher. It clears the terminal now, as in Terminal.app, and the launcher moves to ⌘P.
    /// A map saved before Clear existed still has the launcher on ⌘K. Only that untouched shortcut moves.
    private func movingLauncherOffCommandK() -> KeyMap {
        guard chords[AppAction.clearBuffer.rawValue] == nil,
              var launch = chords[AppAction.launch.rawValue] else { return self }
        let command = NSEvent.ModifierFlags.command.rawValue
        guard launch.key == "k", launch.modifiers == command else { return self }
        let target = AppAction.launch.defaultChord
        let busy = chords.contains { $0.key != AppAction.launch.rawValue && $0.value.key == target.key && $0.value.modifiers == target.modifiers }
        guard !busy else { return self }
        var next = self
        launch.key = target.key
        launch.keyCode = target.keyCode
        next.chords[AppAction.launch.rawValue] = launch
        return next
    }

    /// The new shortcut wins. Another action that used it loses that shortcut.
    func assigning(_ chord: KeyChord, to action: AppAction) -> KeyMap {
        var next = filled()
        let cleared = KeyChord(key: "", modifiers: 0, keyCode: 0)
        for (key, existing) in next.chords where existing.key == chord.key && existing.modifiers == chord.modifiers && key != action.rawValue {
            next.chords[key] = cleared
        }
        next.chords[action.rawValue] = chord
        return next
    }

    func settingFollow(_ action: AppAction, to follow: AppAction?) -> KeyMap {
        var next = filled()
        var chord = next.chord(action)
        chord.follow = follow?.rawValue
        next.chords[action.rawValue] = chord
        return next
    }

    func restoring(_ action: AppAction) -> KeyMap {
        assigning(action.defaultChord, to: action)
    }
}

/// Text-editing keys that macOS turns into Cocoa commands SwiftTerm does not send to the shell.
/// These match what Terminal.app and iTerm2 send, so readline and zle move by word and line.
enum EditingKeys {
    static func sequence(keyCode: UInt16, flags: NSEvent.ModifierFlags, optionIsMeta: Bool) -> [UInt8]? {
        let held = flags.intersection([.command, .option, .control, .shift])
        if held == .option, !optionIsMeta {
            switch Int(keyCode) {
            case kVK_LeftArrow: return [0x1b, 0x62]
            case kVK_RightArrow: return [0x1b, 0x66]
            case kVK_Delete: return [0x1b, 0x7f]
            default: return nil
            }
        }
        if held == .command {
            switch Int(keyCode) {
            case kVK_LeftArrow: return [0x01]
            case kVK_RightArrow: return [0x05]
            case kVK_Delete: return [0x15]
            default: return nil
            }
        }
        return nil
    }
}

/// Whether a paste should stop and ask. A shell without bracketed paste runs every line as it arrives.
enum PasteGuard {
    static func shouldWarn(_ text: String, bracketed: Bool, enabled: Bool) -> Bool {
        guard enabled, !bracketed else { return false }
        return text.contains { $0.isNewline }
    }

    static func lineCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    static func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .newlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum ShellPath {
    static func quote(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._+-~")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Notification.Name {
    static let aetherBindingsChanged = Notification.Name("aetherBindingsChanged")
}

@MainActor
final class KeybindBoard: NSView {
    private let stack = NSStackView()
    private var cards: [AppAction: KeybindCard] = [:]
    private var recording: AppAction?
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for action in AppAction.allCases {
            let card = KeybindCard(action: action)
            card.onClick = { [weak self] in self?.toggle(action) }
            card.onReset = { [weak self] in self?.restore(action) }
            card.onFollow = { [weak self] follow in
                AppModel.shared.updateSettings { settings in
                    settings.keys = settings.keys.settingFollow(action, to: follow)
                }
                self?.reload()
            }
            card.heightAnchor.constraint(equalToConstant: 46).isActive = true
            cards[action] = card
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func reload() {
        let map = AppModel.shared.settings.keys
        for (action, card) in cards {
            let chord = map.chord(action)
            card.setChord(chord, recording: recording == action, follow: chord.follow.flatMap(AppAction.init(rawValue:)))
        }
    }

    func stopRecording() {
        recording = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        reload()
    }

    private func toggle(_ action: AppAction) {
        if recording == action {
            stopRecording()
            return
        }
        stopRecording()
        recording = action
        reload()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated {
                self?.capture(event) ?? false
            }
            return taken ? nil : event
        }
    }

    /// True when this board ate the key. Keys for any other window are left alone,
    /// so recording a shortcut cannot rebind itself from a key meant for a terminal.
    private func capture(_ event: NSEvent) -> Bool {
        guard let recording, event.window === window else { return false }
        if event.keyCode == 53 {
            stopRecording()
            return true
        }
        guard var chord = KeyChord.capture(event) else { return true }
        chord.follow = AppModel.shared.settings.keys.chord(recording).follow
        AppModel.shared.updateSettings { settings in
            settings.keys = settings.keys.assigning(chord, to: recording)
        }
        stopRecording()
        return true
    }

    private func restore(_ action: AppAction) {
        recording = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        AppModel.shared.updateSettings { settings in
            settings.keys = settings.keys.restoring(action)
        }
        reload()
    }
}

@MainActor
final class KeybindCard: NSView {
    var onClick: (() -> Void)?
    var onReset: (() -> Void)?
    var onFollow: ((AppAction?) -> Void)?
    private let action: AppAction
    private let title = NSTextField(labelWithString: "")
    private let chord = NSButton()
    private let reset = NSButton()
    private let then = NSButton()

    init(action: AppAction) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 46))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        title.stringValue = action.title
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        chord.isBordered = false
        chord.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        chord.contentTintColor = .secondaryLabelColor
        chord.target = self
        chord.action = #selector(pressed)
        chord.setButtonType(.momentaryChange)
        reset.isBordered = false
        reset.title = "Reset"
        reset.font = .systemFont(ofSize: 11, weight: .medium)
        reset.contentTintColor = .secondaryLabelColor
        reset.target = self
        reset.action = #selector(resetPressed)
        reset.setButtonType(.momentaryChange)
        then.isBordered = false
        then.title = "Then"
        then.font = .systemFont(ofSize: 11, weight: .medium)
        then.contentTintColor = .tertiaryLabelColor
        then.target = self
        then.action = #selector(thenPressed)
        then.setButtonType(.momentaryChange)
        addSubview(title)
        addSubview(then)
        addSubview(reset)
        addSubview(chord)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setChord(_ value: KeyChord, recording: Bool, follow: AppAction?) {
        chord.title = recording ? "Press a key" : value.symbol
        then.title = follow.map { "then \($0.title)" } ?? "Then"
        chord.contentTintColor = recording ? .labelColor : .secondaryLabelColor
        let stock = value.key == action.defaultChord.key && value.modifiers == action.defaultChord.modifiers && follow == nil
        reset.isEnabled = !stock && !recording
        reset.alphaValue = reset.isEnabled ? 1 : 0.35
        layer?.borderColor = (recording ? NSColor.labelColor.withAlphaComponent(0.55) : NSColor.separatorColor.withAlphaComponent(0.45)).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let chordWidth = max(88, chord.intrinsicContentSize.width + 8)
        let resetWidth: CGFloat = 48
        let thenWidth = max(52, then.intrinsicContentSize.width + 6)
        chord.frame = NSRect(x: bounds.width - chordWidth - 12, y: 8, width: chordWidth, height: 30)
        reset.frame = NSRect(x: chord.frame.minX - resetWidth - 4, y: 8, width: resetWidth, height: 30)
        then.frame = NSRect(x: reset.frame.minX - thenWidth - 2, y: 8, width: thenWidth, height: 30)
        title.frame = NSRect(x: 14, y: 14, width: max(0, then.frame.minX - 22), height: 18)
    }

    @objc private func pressed() {
        onClick?()
    }

    @objc private func resetPressed() {
        onReset?()
    }

    @objc private func thenPressed() {
        let menu = NSMenu()
        let none = NSMenuItem(title: "Nothing after", action: #selector(chooseFollow(_:)), keyEquivalent: "")
        none.target = self
        menu.addItem(none)
        for action in [AppAction.equalize, .fill, .newPane, .splitRight, .insertPath] {
            let item = NSMenuItem(title: action.title, action: #selector(chooseFollow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: then.bounds.height), in: then)
    }

    @objc private func chooseFollow(_ sender: NSMenuItem) {
        let follow = (sender.representedObject as? String).flatMap(AppAction.init(rawValue:))
        onFollow?(follow)
    }
}
