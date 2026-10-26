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

extension KeyChord {
    static let unassigned = KeyChord(key: "", modifiers: 0, keyCode: 0)

    func sameKeys(as other: KeyChord) -> Bool {
        key == other.key && modifiers == other.modifiers
    }

    /// What VoiceOver reads: "Command Shift D".
    var spoken: String {
        guard !key.isEmpty else { return "No shortcut" }
        var words: [String] = []
        let flags = self.flags
        if flags.contains(.control) { words.append("Control") }
        if flags.contains(.option) { words.append("Option") }
        if flags.contains(.command) { words.append("Command") }
        if flags.contains(.shift) { words.append("Shift") }
        words.append(Self.spokenKey(key))
        return words.joined(separator: " ")
    }

    static func spokenKey(_ key: String) -> String {
        switch key {
        case "\r": return "Return"
        case "\t": return "Tab"
        case " ": return "Space"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "Left Arrow"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "Right Arrow"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "Up Arrow"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "Down Arrow"
        case String(UnicodeScalar(NSBackspaceCharacter)!): return "Delete"
        case "`": return "Grave Accent"
        case "=": return "Equals"
        case "-": return "Minus"
        case ",": return "Comma"
        case ".": return "Period"
        case "/": return "Slash"
        case ";": return "Semicolon"
        case "'": return "Quote"
        case "[": return "Left Bracket"
        case "]": return "Right Bracket"
        case "\\": return "Backslash"
        default: return pretty(key)
        }
    }
}

extension KeyMap {
    /// Actions other than `action` that already use this chord, in menu order.
    func holders(of chord: KeyChord, except action: AppAction) -> [AppAction] {
        guard !chord.key.isEmpty else { return [] }
        let map = filled()
        return AppAction.allCases.filter { $0 != action && map.chord($0).sameKeys(as: chord) }
    }
}

extension AppAction {
    /// Actions that can run a second action after themselves. AppDelegate.finish runs the follow.
    static let chainable: Set<AppAction> = [.newWindow, .newPane, .splitRight, .splitDown, .fill, .equalize, .launch, .insertPath]

    /// What can come after. Each is something AppDelegate.finish knows how to run.
    static let chainTargets: [AppAction] = [.equalize, .fill, .newPane, .newWindow, .splitRight, .splitDown, .nextLayout, .insertPath]

    var canChain: Bool { Self.chainable.contains(self) }
}

/// Chords a shortcut should not take, and ones that work but cost something.
enum ShortcutRules {
    enum Verdict: Equatable {
        case fine
        /// macOS or every Mac app already uses it. The reason reads after the chord: "⌘Tab switches apps".
        case reserved(String)
        /// Works, but Option alone stops that key from typing characters like é.
        case optionOnly
    }

    private struct Reserved {
        var keyCode: Int
        var flags: NSEvent.ModifierFlags
        var reason: String
        var allowed: AppAction?
    }

    private static let reserved: [Reserved] = [
        Reserved(keyCode: kVK_Tab, flags: [.command], reason: "switches apps"),
        Reserved(keyCode: kVK_Tab, flags: [.command, .shift], reason: "switches apps"),
        Reserved(keyCode: kVK_Space, flags: [.command], reason: "opens Spotlight"),
        Reserved(keyCode: kVK_Space, flags: [.command, .option], reason: "opens a Finder search"),
        Reserved(keyCode: kVK_Space, flags: [.control], reason: "switches input sources"),
        Reserved(keyCode: kVK_Space, flags: [.control, .option], reason: "switches input sources"),
        Reserved(keyCode: kVK_Space, flags: [.control, .command], reason: "opens Emoji & Symbols"),
        Reserved(keyCode: kVK_ANSI_Q, flags: [.command], reason: "quits Aether", allowed: .quit),
        Reserved(keyCode: kVK_ANSI_Q, flags: [.command, .control], reason: "locks the screen"),
        Reserved(keyCode: kVK_ANSI_Q, flags: [.command, .shift], reason: "logs you out"),
        Reserved(keyCode: kVK_ANSI_H, flags: [.command], reason: "hides Aether"),
        Reserved(keyCode: kVK_ANSI_H, flags: [.command, .option], reason: "hides other apps"),
        Reserved(keyCode: kVK_ANSI_M, flags: [.command], reason: "minimizes the window"),
        Reserved(keyCode: kVK_ANSI_Grave, flags: [.command], reason: "moves between windows"),
        Reserved(keyCode: kVK_ANSI_Grave, flags: [.command, .shift], reason: "moves between windows"),
        Reserved(keyCode: kVK_ANSI_F, flags: [.command, .control], reason: "enters full screen"),
        Reserved(keyCode: kVK_ANSI_3, flags: [.command, .shift], reason: "takes a screenshot"),
        Reserved(keyCode: kVK_ANSI_4, flags: [.command, .shift], reason: "takes a screenshot"),
        Reserved(keyCode: kVK_ANSI_5, flags: [.command, .shift], reason: "takes a screenshot"),
        Reserved(keyCode: kVK_Escape, flags: [.command, .option], reason: "opens Force Quit"),
    ]

    static func verdict(_ chord: KeyChord, for action: AppAction) -> Verdict {
        guard !chord.key.isEmpty else { return .fine }
        let held = chord.flags.intersection([.command, .option, .control, .shift])
        if let hit = reserved.first(where: { Int(chord.keyCode) == $0.keyCode && held == $0.flags }), hit.allowed != action {
            return .reserved(hit.reason)
        }
        if held.contains(.option), !held.contains(.command), !held.contains(.control) {
            return .optionOnly
        }
        return .fine
    }
}

/// How the Keys list is split up.
enum ShortcutGroup: String, CaseIterable, Sendable {
    case windows
    case layout
    case focus
    case resize
    case text
    case find
    case app

    var title: String {
        switch self {
        case .windows: "Windows & Panes"
        case .layout: "Layout"
        case .focus: "Focus"
        case .resize: "Resize"
        case .text: "Text"
        case .find: "Find"
        case .app: "App"
        }
    }

    static func of(_ action: AppAction) -> ShortcutGroup {
        switch action {
        case .newWindow, .newPane, .splitRight, .splitDown, .closePane, .closeWindow, .broadcast,
             .renamePane, .restartPane, .swapNext, .movePaneToWindow: .windows
        case .fill, .equalize, .nextLayout, .previousLayout: .layout
        case .focusLeft, .focusRight, .focusUp, .focusDown, .previousPane, .nextPane,
             .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7, .focusPane8, .focusPane9: .focus
        case .growLeft, .growRight, .growUp, .growDown: .resize
        case .fontUp, .fontDown, .fontReset, .copy, .paste, .selectAll, .clearBuffer, .insertPath: .text
        case .find, .findNext, .findPrevious: .find
        case .launch, .settings, .dropdown, .quit, .shortcuts: .app
        }
    }

    /// Every word of the query has to appear in the name, the group, or the shortcut.
    static func matches(_ action: AppAction, query: String, keys: KeyMap) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let chord = keys.chord(action)
        let text = [action.title, of(action).title, chord.symbol, chord.spoken].joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    static func sections(matching query: String, keys: KeyMap) -> [(group: ShortcutGroup, actions: [AppAction])] {
        allCases.compactMap { group in
            let actions = AppAction.allCases.filter { of($0) == group && matches($0, query: query, keys: keys) }
            return actions.isEmpty ? nil : (group, actions)
        }
    }
}

/// The line under a shortcut after it changes, and what Undo puts back.
struct ShortcutNote: Equatable {
    enum Kind: Equatable {
        case assigned(KeyChord, displaced: [AppAction], optionOnly: Bool)
        case unassigned(AppAction)
        case reserved(KeyChord, String)
        case needsModifier
        case restoredAll
    }

    var kind: Kind
    var undo: KeyMap?

    var message: String {
        switch kind {
        case .assigned(let chord, let displaced, let optionOnly):
            var parts: [String] = []
            if !displaced.isEmpty {
                let names = displaced.map(\.title)
                let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
                parts.append("\(chord.symbol) was \(list) — now unassigned")
            }
            if optionOnly {
                parts.append("Option-only shortcuts stop \(chord.symbol) from typing a character")
            }
            return parts.joined(separator: ". ")
        case .unassigned(let action):
            return "\(action.title) has no shortcut now"
        case .reserved(let chord, let reason):
            return "\(chord.symbol) \(reason), so Aether can't use it"
        case .needsModifier:
            return "Hold ⌘, ⌥, or ⌃ with the key. Delete removes the shortcut."
        case .restoredAll:
            return "Every shortcut is back to its default"
        }
    }

    var isWarning: Bool {
        switch kind {
        case .reserved, .needsModifier: true
        case .assigned(_, let displaced, let optionOnly): optionOnly && displaced.isEmpty
        default: false
        }
    }
}

/// Records one shortcut at a time for every place in Settings that shows one.
@MainActor
final class ShortcutRecorder {
    private(set) var recording: AppAction?
    private(set) var note: ShortcutNote?
    weak var window: NSWindow?
    private var monitor: Any?
    private var listeners: [() -> Void] = []

    func observe(_ body: @escaping () -> Void) {
        listeners.append(body)
    }

    private func changed() {
        listeners.forEach { $0() }
    }

    func toggle(_ action: AppAction) {
        if recording == action {
            stop()
            return
        }
        stopMonitor()
        recording = action
        note = nil
        // A global shortcut never reaches the window while it is registered, so it could not be recorded.
        HotkeyCenter.apply(enabled: false, chord: AppModel.shared.settings.keys.chord(.dropdown))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated {
                self?.capture(event) ?? false
            }
            return taken ? nil : event
        }
        changed()
    }

    func stop() {
        let was = recording
        stopMonitor()
        if was != nil { changed() }
    }

    func clearNote() {
        guard note != nil else { return }
        note = nil
        changed()
    }

    private func stopMonitor() {
        let was = recording
        recording = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if was != nil {
            let settings = AppModel.shared.settings
            HotkeyCenter.apply(enabled: settings.dropdownEnabled && !System.isDev, chord: settings.keys.chord(.dropdown))
        }
    }

    /// True when the recorder ate the key. Keys for any other window are left alone,
    /// so recording a shortcut cannot rebind itself from a key meant for a terminal.
    private func capture(_ event: NSEvent) -> Bool {
        guard let action = recording, let window, event.window === window else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return true
        }
        let held = event.modifierFlags.intersection([.command, .option, .control])
        if held.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            unassign(action)
            return true
        }
        guard var chord = KeyChord.capture(event) else {
            note = ShortcutNote(kind: .needsModifier)
            changed()
            return true
        }
        let verdict = ShortcutRules.verdict(chord, for: action)
        if case .reserved(let reason) = verdict {
            note = ShortcutNote(kind: .reserved(chord, reason))
            changed()
            return true
        }
        let before = AppModel.shared.settings.keys
        chord.follow = before.chord(action).follow
        let displaced = before.holders(of: chord, except: action)
        stopMonitor()
        AppModel.shared.updateSettings { settings in
            settings.keys = settings.keys.assigning(chord, to: action)
        }
        let quiet = displaced.isEmpty && verdict != .optionOnly
        note = quiet ? nil : ShortcutNote(kind: .assigned(chord, displaced: displaced, optionOnly: verdict == .optionOnly), undo: before)
        changed()
        return true
    }

    func unassign(_ action: AppAction) {
        let before = AppModel.shared.settings.keys
        stopMonitor()
        guard !before.chord(action).key.isEmpty else {
            changed()
            return
        }
        AppModel.shared.updateSettings { settings in
            var map = settings.keys.filled()
            map.chords[action.rawValue] = .unassigned
            settings.keys = map
        }
        note = ShortcutNote(kind: .unassigned(action), undo: before)
        changed()
    }

    func restore(_ action: AppAction) {
        let before = AppModel.shared.settings.keys
        stopMonitor()
        let chord = action.defaultChord
        let displaced = before.holders(of: chord, except: action)
        AppModel.shared.updateSettings { settings in
            settings.keys = settings.keys.restoring(action)
        }
        note = displaced.isEmpty ? nil : ShortcutNote(kind: .assigned(chord, displaced: displaced, optionOnly: false), undo: before)
        changed()
    }

    func restoreAll() {
        let before = AppModel.shared.settings.keys
        stopMonitor()
        guard before.filled() != KeyMap.standard else {
            changed()
            return
        }
        AppModel.shared.updateSettings { $0.keys = .standard }
        note = ShortcutNote(kind: .restoredAll, undo: before)
        changed()
    }

    func setFollow(_ action: AppAction, to follow: AppAction?) {
        stopMonitor()
        AppModel.shared.updateSettings { settings in
            settings.keys = settings.keys.settingFollow(action, to: follow)
        }
        changed()
    }

    func undo() {
        guard let previous = note?.undo else { return }
        stopMonitor()
        AppModel.shared.updateSettings { $0.keys = previous }
        note = nil
        changed()
    }
}

/// "⌘D was Split right — now unassigned · Undo". Hidden while there is nothing to say.
@MainActor
final class ShortcutNoteBar: NSStackView {
    var onUndo: (() -> Void)?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let undo = NSButton(title: "Undo", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 8
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 420
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undo.bezelStyle = .inline
        undo.controlSize = .small
        undo.font = .systemFont(ofSize: 12, weight: .medium)
        undo.target = self
        undo.action = #selector(undoPressed)
        undo.setAccessibilityLabel("Undo shortcut change")
        addArrangedSubview(label)
        addArrangedSubview(undo)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ note: ShortcutNote?) {
        guard let note else {
            isHidden = true
            return
        }
        label.stringValue = note.message
        label.textColor = note.isWarning ? .systemOrange : .secondaryLabelColor
        undo.isHidden = note.undo == nil
        isHidden = false
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [
            .announcement: note.message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    @objc private func undoPressed() {
        onUndo?()
    }
}

/// A button that shows a shortcut and records a new one when pressed.
@MainActor
final class ShortcutButton: NSButton {
    let shortcut: AppAction

    init(action shortcut: AppAction, recorder: ShortcutRecorder) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(pressed)
        toolTip = "Click, then press the new keys. Delete removes it. Esc cancels."
        self.recorder = recorder
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
    }

    private weak var recorder: ShortcutRecorder?

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh(_ chord: KeyChord, recording: Bool) {
        title = recording ? "Type keys…" : (chord.key.isEmpty ? "Not set" : chord.symbol)
        setAccessibilityLabel("\(shortcut.title), \(recording ? "recording. Press the new keys" : chord.spoken)")
    }

    @objc private func pressed() {
        recorder?.toggle(shortcut)
    }
}

@MainActor
final class KeybindBoard: NSView {
    private let stack = NSStackView()
    private let recorder: ShortcutRecorder
    private var rows: [AppAction: KeybindRow] = [:]
    private var headers: [ShortcutGroup: NSView] = [:]
    private let empty = NSTextField(labelWithString: "No shortcuts match")
    private var query = ""

    override var isFlipped: Bool { true }

    init(recorder: ShortcutRecorder) {
        self.recorder = recorder
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for group in ShortcutGroup.allCases {
            let header = NSTextField(labelWithString: group.title)
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.setAccessibilityRole(.staticText)
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            header.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8),
                header.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
                wrap.heightAnchor.constraint(equalToConstant: group == ShortcutGroup.allCases.first ? 22 : 32),
            ])
            headers[group] = wrap
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for action in AppAction.allCases where ShortcutGroup.of(action) == group {
                let row = KeybindRow(action: action, recorder: recorder)
                row.heightAnchor.constraint(equalToConstant: 28).isActive = true
                rows[action] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        stack.addArrangedSubview(empty)
        recorder.observe { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func filter(_ text: String) {
        query = text
        reload()
    }

    func reload() {
        let map = AppModel.shared.settings.keys
        let sections = ShortcutGroup.sections(matching: query, keys: map)
        let shown = Set(sections.flatMap(\.actions))
        for (group, header) in headers {
            header.isHidden = !sections.contains { $0.group == group }
        }
        for (action, row) in rows {
            row.isHidden = !shown.contains(action)
            let chord = map.chord(action)
            row.setChord(chord, recording: recorder.recording == action, follow: chord.follow.flatMap(AppAction.init(rawValue:)))
        }
        empty.isHidden = !shown.isEmpty
    }
}

@MainActor
final class KeybindRow: NSView {
    private let action: AppAction
    private weak var recorder: ShortcutRecorder?
    private let title = NSTextField(labelWithString: "")
    private let chord: ShortcutButton
    private let reset = NSButton()
    private let then = NSButton()

    init(action: AppAction, recorder: ShortcutRecorder) {
        self.action = action
        self.recorder = recorder
        chord = ShortcutButton(action: action, recorder: recorder)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        title.stringValue = action.title
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        chord.translatesAutoresizingMaskIntoConstraints = true
        reset.isBordered = false
        reset.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        reset.contentTintColor = .secondaryLabelColor
        reset.toolTip = "Restore the default, \(action.defaultChord.symbol)"
        reset.setAccessibilityLabel("Restore default shortcut for \(action.title), \(action.defaultChord.spoken)")
        reset.target = self
        reset.action = #selector(resetPressed)
        then.isBordered = false
        then.font = .systemFont(ofSize: 12)
        then.contentTintColor = .secondaryLabelColor
        then.toolTip = "Run another action after this one"
        then.target = self
        then.action = #selector(thenPressed)
        then.isHidden = !action.canChain
        addSubview(title)
        addSubview(then)
        addSubview(reset)
        addSubview(chord)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setChord(_ value: KeyChord, recording: Bool, follow: AppAction?) {
        chord.refresh(value, recording: recording)
        then.title = follow.map { "then \($0.title)" } ?? "+ Then…"
        then.setAccessibilityLabel(follow.map { "After \(action.title), run \($0.title)" } ?? "Run another action after \(action.title)")
        let stock = value.sameKeys(as: action.defaultChord) && follow == nil
        reset.isHidden = stock || recording
        layer?.backgroundColor = recording ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let chordWidth = max(96, chord.intrinsicContentSize.width + 8)
        let height = bounds.height
        chord.frame = NSRect(x: bounds.width - chordWidth - 6, y: (height - 22) / 2, width: chordWidth, height: 22)
        reset.frame = NSRect(x: chord.frame.minX - 26, y: (height - 20) / 2, width: 20, height: 20)
        let thenWidth = then.isHidden ? 0 : min(190, then.intrinsicContentSize.width + 6)
        then.frame = NSRect(x: reset.frame.minX - thenWidth - 6, y: (height - 20) / 2, width: thenWidth, height: 20)
        let titleRight = then.isHidden ? reset.frame.minX : then.frame.minX
        title.frame = NSRect(x: 8, y: (height - 17) / 2, width: max(0, titleRight - 16), height: 17)
    }

    @objc private func resetPressed() {
        recorder?.restore(action)
    }

    @objc private func thenPressed() {
        let menu = NSMenu()
        let none = NSMenuItem(title: "Nothing after", action: #selector(chooseFollow(_:)), keyEquivalent: "")
        none.target = self
        menu.addItem(none)
        menu.addItem(.separator())
        for next in AppAction.chainTargets where next != action {
            let item = NSMenuItem(title: next.title, action: #selector(chooseFollow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = next.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: then.bounds.height + 4), in: then)
    }

    @objc private func chooseFollow(_ sender: NSMenuItem) {
        let follow = (sender.representedObject as? String).flatMap(AppAction.init(rawValue:))
        recorder?.setFollow(action, to: follow)
    }
}
