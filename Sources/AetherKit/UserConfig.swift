import AppKit
import Carbon.HIToolbox
import CoreText
import UniformTypeIdentifiers

/// `~/.config/aether/config`: Ghostty-style `key = value` lines for people who keep their setup in dotfiles.
/// A value in the file wins over the Settings window. Lines that don't parse are reported and skipped.
public struct UserConfig: Equatable, Sendable {
    public struct Problem: Equatable, Sendable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "config line \(line): \(message)" }
    }

    /// One accepted line. The value is already unquoted and known to apply.
    struct Entry: Equatable, Sendable {
        var line: Int
        var key: String
        var value: String
    }

    var entries: [Entry] = []
    public var problems: [Problem] = []

    public init() {}

    public static func parse(_ text: String) -> UserConfig {
        var config = UserConfig()
        var probe = Settings()
        // "\r\n" is one Character in Swift, so split on any newline, not on "\n".
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let number = index + 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                config.problems.append(Problem(line: number, message: "expected `key = value`, got `\(line)`"))
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else {
                config.problems.append(Problem(line: number, message: "missing a key before `=`"))
                continue
            }
            guard let definition = ConfigKey.named[key] else {
                config.problems.append(Problem(line: number, message: "unknown key `\(key)`" + suggestion(key, among: ConfigKey.all.map(\.name))))
                continue
            }
            guard let value = unquote(String(line[line.index(after: equals)...])) else {
                config.problems.append(Problem(line: number, message: "\(key): missing closing quote"))
                continue
            }
            // `key =` with nothing after it leaves that setting to the Settings window.
            if value.isEmpty { continue }
            do {
                try definition.apply(&probe, value)
                config.entries.append(Entry(line: number, key: key, value: value))
            } catch {
                config.problems.append(Problem(line: number, message: "\(key): \((error as? ConfigError)?.message ?? "\(error)")"))
            }
        }
        return config
    }

    /// `settings` with every line of the file applied in order, so a later duplicate wins.
    public func applied(to settings: Settings) -> Settings {
        var out = settings
        for entry in entries {
            try? ConfigKey.named[entry.key]?.apply(&out, entry.value)
        }
        out.clamp()
        return out
    }

    /// What the file sets, with the line that set it last. Shortcuts appear as `keybind:<action>`.
    public var sources: [String: Int] {
        var out: [String: Int] = [:]
        for entry in entries {
            if entry.key == "keybind" {
                if let action = (try? Keybind.parse(entry.value))?.action {
                    out["keybind:\(action.rawValue)"] = entry.line
                }
            } else {
                out[entry.key] = entry.line
            }
        }
        return out
    }

    /// `effective` with everything the file sets put back to `base`, so config.json keeps what the Settings window chose.
    func restoring(_ effective: Settings, from base: Settings) -> Settings {
        var out = effective
        for entry in entries {
            if entry.key == "keybind" {
                guard let bind = try? Keybind.parse(entry.value) else { continue }
                if let action = bind.action {
                    out.keys.chords[action.rawValue] = base.keys.chords[action.rawValue]
                }
                // An action that lost these keys to the file keeps them in the window's map.
                for (name, chord) in base.keys.chords where chord.sameKeys(as: bind.chord) {
                    out.keys.chords[name] = chord
                }
            } else {
                ConfigKey.named[entry.key]?.carry(base, &out)
            }
        }
        return out
    }

    /// Strips a trailing ` # comment` and one pair of quotes. Nil when a quote is left open.
    static func unquote(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let quote = text.first, quote == "\"" || quote == "'" {
            let rest = text.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return nil }
            let after = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard after.isEmpty || after.hasPrefix("#") else { return nil }
            return String(rest[..<end])
        }
        if let comment = text.range(of: #"\s#"#, options: .regularExpression) {
            return text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// " — did you mean `font-size`?" for a near miss, or nothing.
    static func suggestion(_ word: String, among names: [String]) -> String {
        let lowered = word.lowercased()
        let close = names
            .map { ($0, distance(lowered, $0.lowercased())) }
            .filter { $0.1 <= max(2, lowered.count / 3) }
            .min { $0.1 < $1.1 }?.0
        guard let best = close ?? Fuzzy.rank(lowered, names, text: { $0 }).first else { return "" }
        return " — did you mean `\(best)`?"
    }

    /// Edit distance, for typos that a subsequence match misses: `fnot-size`.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// The whole file, commented out, with every key at its default. `aether config defaults` prints it.
    public static func template() -> String {
        let defaults = Settings()
        var lines = [
            "# Aether config: \(UserConfigCenter.displayPath)",
            "#",
            "# One `key = value` per line. Lines starting with # are comments. Quotes are optional.",
            "# A value here wins over the Settings window, which greys that control out.",
            "# Aether reloads this file when you save it. `aether config check` lists mistakes.",
            "# Remove the # in front of a line to use it.",
            "",
        ]
        for key in ConfigKey.all where key.name != "keybind" {
            lines.append("# \(key.help)")
            lines.append("# \(key.name) = \(key.show(defaults))")
            lines.append("")
        }
        lines.append("# Shortcuts: keybind = <keys>=<action>. Modifiers: cmd, shift, ctrl, opt.")
        lines.append("# Keys: a-z, 0-9, punctuation, return, tab, space, backspace, left, right, up, down, f1-f12.")
        lines.append("# `keybind = cmd+k=unbind` frees a shortcut. These are the defaults:")
        var unbound: [String] = []
        for action in AppAction.allCases {
            let chord = action.defaultChord
            if chord.key.isEmpty {
                unbound.append(action.configName)
            } else {
                lines.append("# keybind = \(Keybind.text(chord))=\(action.configName)")
            }
        }
        lines.append("# No shortcut by default: \(unbound.joined(separator: ", ")).")
        return lines.joined(separator: "\n") + "\n"
    }
}

struct ConfigError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// One key the config file understands, and how it reads, writes, and carries its setting.
struct ConfigKey: Sendable {
    let name: String
    let help: String
    let apply: @Sendable (inout Settings, String) throws -> Void
    let show: @Sendable (Settings) -> String
    let carry: @Sendable (Settings, inout Settings) -> Void

    static let named: [String: ConfigKey] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static let all: [ConfigKey] = [
        ConfigKey(name: "theme", help: "Color theme: a built-in name, or one imported into the themes folder.", apply: { settings, value in
            let names = Themes.names()
            guard let name = names.first(where: { $0.lowercased() == value.lowercased() }) else {
                throw ConfigError("no theme `\(value)`" + UserConfig.suggestion(value, among: names))
            }
            settings.themeName = name
        }, show: { $0.themeName }, carry: { $1.themeName = $0.themeName }),
        ConfigKey(name: "font-family", help: "Font family. Empty uses SF Mono, then Menlo.", apply: { settings, value in
            let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
            guard let family = families.first(where: { $0.lowercased() == value.lowercased() }) else {
                throw ConfigError("no font family `\(value)` is installed" + UserConfig.suggestion(value, among: families))
            }
            settings.fontFamily = family
        }, show: { $0.fontFamily }, carry: { $1.fontFamily = $0.fontFamily }),
        ConfigKey(name: "font-size", help: "Text size in points, 10 to 24. ⌘0 goes back to it.", apply: { settings, value in
            let size = try number(value, 10...24)
            settings.fontSize = size
            settings.baseFontSize = size
        }, show: { format($0.baseFontSize) }, carry: { base, out in
            out.fontSize = base.fontSize
            out.baseFontSize = base.baseFontSize
        }),
        number("line-height", \.lineHeight, 0.8...2, "Line height as a multiple of the font's own, 0.8 to 2."),
        choice("glass", \.glass, "Glass behind the text. Clear stays clear when you click away."),
        choice("text-tone", \.text, "Text color. Automatic follows Light and Dark Mode."),
        number("shade", \.shade, 0...0.82, "How dark the glass is, 0 to 0.82."),
        number("minimum-contrast", \.minimumContrast, 0...1, "Raise colors that are hard to read on the glass, 0 to 1."),
        choice("cursor-shape", \.cursorShape, "Cursor shape."),
        flag("cursor-blink", \.cursorBlink, "Blink the cursor."),
        choice("unfocused-panes", \.focusRest, "How panes without focus look."),
        number("blur-amount", \.blurAmount, 0...1, "Frost on unfocused panes when unfocused-panes is blur, 0 to 1."),
        number("corner-radius", \.cornerRadius, 8...32, "Window corner radius in points, 8 to 32."),
        number("gap", \.gap, 2...22, "Space between panes in points, 2 to 22."),
        flag("snap-windows", \.snapWindows, "Snap windows into place when you let go."),
        ConfigKey(name: "option-as-meta", help: "Option sends Meta (Esc+key) to the shell: true, false, or left.", apply: { settings, value in
            switch flat(value) {
            case "left", "leftmeta": settings.optionKey = .leftMeta
            default: settings.optionKey = try bool(value) ? .meta : .characters
            }
        }, show: { settings in
            switch settings.optionKey {
            case .characters: "false"
            case .meta: "true"
            case .leftMeta: "left"
            }
        }, carry: { $1.optionKey = $0.optionKey }),
        choice("shell-exit", \.shellExit, "What a terminal does when its shell exits."),
        flag("warn-multiline-paste", \.warnMultilinePaste, "Ask before pasting several lines into a shell that would run each."),
        flag("copy-on-select", \.copyOnSelect, "Copy text as soon as it's selected."),
        flag("restore-contents", \.restoreContents, "Show each terminal's old text again after Aether restarts."),
        flag("gpu-rendering", \.gpuRendering, "Draw text with Metal. Experimental, and not faster yet."),
        choice("bell", \.bell, "Bell."),
        ConfigKey(name: "scrollback", help: "Lines of scrollback per terminal, 0 to 1000000.", apply: { settings, value in
            settings.scrollbackLines = Int(try number(value, 0...1_000_000))
        }, show: { String($0.scrollbackLines) }, carry: { $1.scrollbackLines = $0.scrollbackLines }),
        flag("shell-integration", \.shellIntegration, "Prompt marks, titles, and command notifications from zsh, bash, and fish."),
        flag("notify-on-finish", \.notifyOnFinish, "Notify when a command finishes in the background."),
        number("notify-after", \.notifyAfterSeconds, 0...86_400, "Seconds a command must run before it notifies."),
        choice("confirm-close", \.confirmClose, "Ask before closing a terminal, a window, or Aether."),
        flag("hide-dock-icon", \.hideDockIcon, "Hide the Dock icon."),
        flag("check-for-updates", \.checkForUpdates, "Check for updates in the background."),
        flag("dropdown", \.dropdownEnabled, "The dropdown terminal and its global shortcut."),
        number("dropdown-height", \.dropdownHeight, 0.2...1, "Share of the screen the dropdown covers, 0.2 to 1."),
        flag("dropdown-hide-on-focus-loss", \.dropdownHideOnFocusLoss, "Hide the dropdown when it loses focus."),
        ConfigKey(name: "keybind", help: "A shortcut: keybind = cmd+shift+t=new_tab. Repeat the key for more.", apply: { settings, value in
            let bind = try Keybind.parse(value)
            if let action = bind.action {
                settings.keys = settings.keys.assigning(bind.chord, to: action)
            } else {
                for (name, chord) in settings.keys.chords where chord.sameKeys(as: bind.chord) {
                    settings.keys.chords[name] = .unassigned
                }
            }
        }, show: { _ in "" }, carry: { _, _ in }),
    ]

    static func number(_ name: String, _ path: WritableKeyPath<Settings, Double> & Sendable, _ range: ClosedRange<Double>, _ help: String) -> ConfigKey {
        ConfigKey(name: name, help: help, apply: { settings, value in
            settings[keyPath: path] = try number(value, range)
        }, show: { format($0[keyPath: path]) }, carry: { $1[keyPath: path] = $0[keyPath: path] })
    }

    static func flag(_ name: String, _ path: WritableKeyPath<Settings, Bool> & Sendable, _ help: String) -> ConfigKey {
        ConfigKey(name: name, help: help, apply: { settings, value in
            settings[keyPath: path] = try bool(value)
        }, show: { $0[keyPath: path] ? "true" : "false" }, carry: { $1[keyPath: path] = $0[keyPath: path] })
    }

    static func choice<E: RawRepresentable & CaseIterable & Sendable>(_ name: String, _ path: WritableKeyPath<Settings, E> & Sendable, _ help: String) -> ConfigKey where E.RawValue == String {
        let names = E.allCases.map { kebab($0.rawValue) }
        return ConfigKey(name: name, help: "\(help) One of: \(names.joined(separator: ", ")).", apply: { settings, value in
            guard let match = E.allCases.first(where: { flat($0.rawValue) == flat(value) }) else {
                throw ConfigError("`\(value)` is not one of \(names.joined(separator: ", "))" + UserConfig.suggestion(value, among: names))
            }
            settings[keyPath: path] = match
        }, show: { kebab($0[keyPath: path].rawValue) }, carry: { $1[keyPath: path] = $0[keyPath: path] })
    }

    static func number(_ value: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let number = Double(value), number.isFinite else { throw ConfigError("`\(value)` is not a number") }
        guard range.contains(number) else { throw ConfigError("\(value) is outside \(format(range.lowerBound)) to \(format(range.upperBound))") }
        return number
    }

    static func bool(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw ConfigError("`\(value)` is not true or false")
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// Lowercase with dashes and underscores gone, so `when-busy`, `when_busy`, and `whenBusy` all match.
func flat(_ text: String) -> String {
    text.lowercased().filter { $0 != "-" && $0 != "_" }
}

/// `whenBusy` → `when-busy`.
func kebab(_ camel: String) -> String {
    snake(camel).replacingOccurrences(of: "_", with: "-")
}

/// `newTab` → `new_tab`, `focusPane1` → `focus_pane_1`.
func snake(_ camel: String) -> String {
    var out = ""
    var previous: Character?
    for character in camel {
        if let previous, character.isUppercase || (character.isNumber && !previous.isNumber) {
            out.append("_")
        }
        out.append(contentsOf: character.lowercased())
        previous = character
    }
    return out
}

extension AppAction {
    /// The name config files use: `new_tab`.
    var configName: String { snake(rawValue) }
}

/// `cmd+shift+t=new_tab`. No action means `unbind`: whatever holds those keys lets go.
struct Keybind: Equatable {
    var chord: KeyChord
    var action: AppAction?

    static func parse(_ text: String) throws -> Keybind {
        guard let split = text.lastIndex(of: "="), split != text.startIndex else {
            throw ConfigError("write a shortcut as `keybind = cmd+shift+t=new_tab`")
        }
        let trigger = text[..<split].trimmingCharacters(in: .whitespaces)
        let name = text[text.index(after: split)...].trimmingCharacters(in: .whitespaces)
        let chord = try Self.chord(trigger)
        if flat(name) == "unbind" { return Keybind(chord: chord, action: nil) }
        guard let action = AppAction.allCases.first(where: { flat($0.rawValue) == flat(name) }) else {
            let names = AppAction.allCases.map(\.configName) + ["unbind"]
            throw ConfigError(name.isEmpty ? "say which action, like `\(trigger)=new_tab`" : "unknown action `\(name)`" + UserConfig.suggestion(name, among: names))
        }
        return Keybind(chord: chord, action: action)
    }

    static func chord(_ text: String) throws -> KeyChord {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // `cmd++` is the plus key: the split leaves two empty parts at the end.
        if parts.count >= 3, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let name = parts.popLast(), !name.isEmpty else { throw ConfigError("`\(text)` has no key") }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd", "command", "super", "⌘": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "ctrl", "control", "⌃": flags.insert(.control)
            case "opt", "option", "alt", "⌥": flags.insert(.option)
            default: throw ConfigError("unknown modifier `\(part)`; use cmd, shift, ctrl, or opt")
            }
        }
        guard !flags.isDisjoint(with: [.command, .control, .option]) else {
            throw ConfigError("`\(text)` needs cmd, ctrl, or opt, so plain typing still reaches the shell")
        }
        guard let key = keys[name] else {
            throw ConfigError("unknown key `\(name)`" + UserConfig.suggestion(name, among: keys.keys.filter { $0.count > 1 }.sorted()))
        }
        return KeyChord(key: key.0, modifiers: flags.rawValue, keyCode: UInt16(key.1))
    }

    /// `cmd+shift+t`, the way a config file writes it.
    static func text(_ chord: KeyChord) -> String {
        var parts: [String] = []
        let flags = chord.flags
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        let name = names.first { $0.1 == chord.key }?.0 ?? chord.key
        return (parts + [name]).joined(separator: "+")
    }

    /// Key names and what KeyChord stores for them: the character and the ANSI key code.
    /// Earlier names win when writing a chord back out.
    private static let names: [(String, String, Int)] = {
        var list: [(String, String, Int)] = []
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
                       kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                       kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letters) {
            list.append((String(letter), String(letter), code))
        }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in zip("0123456789", digits) {
            list.append((String(digit), String(digit), code))
        }
        let function = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in function.enumerated() {
            list.append(("f\(index + 1)", String(UnicodeScalar(UInt32(NSF1FunctionKey + index))!), code))
        }
        let arrow = { (value: Int) in String(UnicodeScalar(UInt32(value))!) }
        list += [
            ("equal", "=", kVK_ANSI_Equal), ("grave", "`", kVK_ANSI_Grave),
            ("return", "\r", kVK_Return), ("tab", "\t", kVK_Tab), ("space", " ", kVK_Space),
            ("backspace", arrow(NSBackspaceCharacter), kVK_Delete),
            ("left", arrow(NSLeftArrowFunctionKey), kVK_LeftArrow), ("right", arrow(NSRightArrowFunctionKey), kVK_RightArrow),
            ("up", arrow(NSUpArrowFunctionKey), kVK_UpArrow), ("down", arrow(NSDownArrowFunctionKey), kVK_DownArrow),
            ("-", "-", kVK_ANSI_Minus), ("[", "[", kVK_ANSI_LeftBracket), ("]", "]", kVK_ANSI_RightBracket),
            ("\\", "\\", kVK_ANSI_Backslash), (";", ";", kVK_ANSI_Semicolon), ("'", "'", kVK_ANSI_Quote),
            (",", ",", kVK_ANSI_Comma), (".", ".", kVK_ANSI_Period), ("/", "/", kVK_ANSI_Slash),
            ("=", "=", kVK_ANSI_Equal), ("`", "`", kVK_ANSI_Grave),
            // The plus key is the equals key. Menus match "=" for ⌘=, so that is what gets stored.
            ("+", "=", kVK_ANSI_Equal), ("plus", "=", kVK_ANSI_Equal),
            ("enter", "\r", kVK_Return), ("delete", arrow(NSBackspaceCharacter), kVK_Delete),
            ("minus", "-", kVK_ANSI_Minus), ("comma", ",", kVK_ANSI_Comma), ("period", ".", kVK_ANSI_Period),
            ("slash", "/", kVK_ANSI_Slash), ("backslash", "\\", kVK_ANSI_Backslash), ("semicolon", ";", kVK_ANSI_Semicolon),
            ("quote", "'", kVK_ANSI_Quote), ("backtick", "`", kVK_ANSI_Grave),
            ("bracketleft", "[", kVK_ANSI_LeftBracket), ("bracketright", "]", kVK_ANSI_RightBracket),
        ]
        return list
    }()

    private static let keys: [String: (String, Int)] = {
        var table: [String: (String, Int)] = [:]
        for (name, key, code) in names where table[name] == nil {
            table[name] = (key, code)
        }
        return table
    }()
}

/// Reads and watches the config file, and keeps track of what the Settings window chose underneath it.
@MainActor
final class UserConfigCenter {
    static let shared = UserConfigCenter()

    private(set) var config = UserConfig()
    /// The file exists. Settings shows a note while it does.
    private(set) var active = false
    /// The Settings window's values, before the file. This is what config.json keeps.
    private var base: Settings?
    private var lastText: String?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    nonisolated static func fileURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = System.home()) -> URL {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".config")
        return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("aether").appendingPathComponent("config")
    }

    /// `~/.config/aether/config`, for people to read.
    nonisolated static var displayPath: String {
        let path = fileURL().path
        let home = System.home()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    nonisolated static func lockNote(line: Int) -> String {
        "Set by \(displayPath), line \(line)"
    }

    /// The launch settings: the window's values with the file on top. Starts watching for saves.
    func start(_ windowSettings: Settings) -> Settings {
        base = windowSettings
        let text = read()
        lastText = text
        config = UserConfig.parse(text ?? "")
        watch()
        report(delay: 1.2)
        return config.applied(to: windowSettings)
    }

    /// `settings` without the file: what config.json should hold.
    func forWindow(_ settings: Settings) -> Settings {
        let restored = config.restoring(settings, from: base ?? settings)
        base = restored
        return restored
    }

    /// Creates the file from the template if it is missing, then opens it in the text editor.
    func openFile() {
        let url = Self.fileURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? UserConfig.template().write(to: url, atomically: true, encoding: .utf8)
            watch()
            reload()
        }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// `aether config path|check|defaults`.
    func agentReply(_ body: [String: Any]) -> [String: Any] {
        let path = Self.fileURL().path
        switch body["action"] as? String ?? "path" {
        case "path":
            return ["ok": true, "path": path, "exists": FileManager.default.fileExists(atPath: path)]
        case "defaults":
            return ["ok": true, "text": UserConfig.template()]
        case "check":
            let file = body["file"] as? String ?? path
            let checked = (body["text"] as? String).map(UserConfig.parse) ?? UserConfig.parse(read() ?? "")
            let problems = checked.problems.map { ["line": $0.line, "message": $0.message, "text": $0.description] as [String: Any] }
            return ["ok": true, "path": file, "settings": checked.entries.count, "problems": problems]
        default:
            return ["ok": false, "error": "Use path, check, or defaults."]
        }
    }

    private func read() -> String? {
        let url = Self.fileURL()
        active = FileManager.default.fileExists(atPath: url.path)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func reload() {
        let text = read()
        guard text != lastText else { return }
        // Peel the old file off with the old rules before the new file goes on.
        let windowSettings = forWindow(AppModel.shared.settings)
        lastText = text
        config = UserConfig.parse(text ?? "")
        report(delay: 0)
        AppModel.shared.updateSettings { $0 = config.applied(to: windowSettings) }
    }

    private func report(delay: TimeInterval) {
        for problem in config.problems {
            NSLog("Aether: %@ %@", Self.displayPath, problem.description)
        }
        guard let first = config.problems.first else { return }
        let more = config.problems.count > 1 ? " (+\(config.problems.count - 1) more: aether config check)" : ""
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                AppModel.shared.flashNotice(first.description + more)
            }
        }
    }

    /// Watches the folder for editors that save by writing a new file and renaming it (vim, most IDEs),
    /// and the file itself for editors that write in place. Every event re-arms both.
    private func watch() {
        sources.forEach { $0.cancel() }
        sources = []
        let url = Self.fileURL()
        let folder = url.deletingLastPathComponent()
        // Until ~/.config/aether exists, watch ~/.config so making it is noticed.
        let watched = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        for (path, mask) in [(watched.path, DispatchSource.FileSystemEvent.write), (url.path, [.write, .extend, .delete, .rename])] {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.changed() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.watch()
                self?.reload()
            }
        }
        pending = work
        // Editors write in a few steps. Wait for them to finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
