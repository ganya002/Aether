import Foundation

public enum GlassStyle: String, Codable, CaseIterable, Sendable {
    case clear
    case regular

    public var title: String {
        switch self {
        case .clear: "Clear"
        case .regular: "Regular"
        }
    }
}

public enum TextTone: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    /// Follows the system appearance: light text in Dark Mode, dark text in Light Mode.
    case automatic

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .automatic: "Automatic"
        }
    }

    /// Light or dark, with Automatic settled by the system appearance.
    public func resolved(darkMode: Bool) -> TextTone {
        switch self {
        case .automatic: darkMode ? .light : .dark
        default: self
        }
    }
}

public enum CursorShape: String, Codable, CaseIterable, Sendable {
    case block
    case underline
    case bar

    public var title: String {
        switch self {
        case .block: "Block"
        case .underline: "Underline"
        case .bar: "Bar"
        }
    }
}

public enum BellStyle: String, Codable, CaseIterable, Sendable {
    case visual
    case sound
    case none

    public var title: String {
        switch self {
        case .visual: "Flash"
        case .sound: "Sound"
        case .none: "Off"
        }
    }
}

/// How panes that are not focused sit behind the one that is.
public enum FocusRest: String, Codable, CaseIterable, Sendable {
    case dim
    case blur
    case unchanged

    public var title: String {
        switch self {
        case .dim: "Dim"
        case .blur: "Blur"
        case .unchanged: "As is"
        }
    }
}

/// When the window is not key, and when a pane is not focused.
enum GlassFocus {
    /// Fade frost in or out. Long enough to see, short enough to feel instant.
    static let blurDuration: TimeInterval = 0.26

    /// Clear glass stays liquid when Aether is in the background.
    static func keepsClearWhenInactive(_ glass: GlassStyle) -> Bool {
        glass == .clear
    }

    /// Regular glass eases into frost when the window is not key. Clear never does.
    static func windowFrostsWhenInactive(_ glass: GlassStyle) -> Bool {
        glass == .regular
    }

    /// Content blur on an unfocused pane. Clear glass does not frost, even if Blur is selected.
    static func paneBlurRadius(focused: Bool, glass: GlassStyle, rest: FocusRest, amount: Double) -> CGFloat {
        guard !focused, glass != .clear, rest == .blur, amount > 0.01 else { return 0 }
        return CGFloat(16 + amount * 26)
    }

    static func blursUnfocusedPane(glass: GlassStyle, rest: FocusRest) -> Bool {
        glass != .clear && rest == .blur
    }
}

/// When closing a terminal, a window, or Aether itself should ask first.
public enum ConfirmClose: String, Codable, CaseIterable, Sendable {
    case whenBusy
    case always
    case never

    public var title: String {
        switch self {
        case .whenBusy: "When something is running"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// What the Option key sends to the shell.
public enum OptionKey: String, Codable, CaseIterable, Sendable {
    case characters
    case meta
    case leftMeta

    public var title: String {
        switch self {
        case .characters: "Types characters"
        case .meta: "Acts as Meta"
        case .leftMeta: "Left Option is Meta"
        }
    }
}

/// What happens to a terminal once its shell exits.
public enum ShellExit: String, Codable, CaseIterable, Sendable {
    case close
    case keep

    public var title: String {
        switch self {
        case .close: "Close the terminal"
        case .keep: "Keep it open"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var shade: Double
    public var glass: GlassStyle
    public var text: TextTone
    public var fontSize: Double
    public var cornerRadius: Double
    public var gap: Double
    public var snapWindows: Bool
    public var focusRest: FocusRest
    /// How strong the frost is on an unfocused pane when Blur is selected. 0 is clear, 1 is heavy.
    public var blurAmount: Double
    public var notifyOnFinish: Bool
    /// Background checks. Off, Aether only looks when you ask, and nothing installs until you say so.
    public var checkForUpdates: Bool
    public var dropdownEnabled: Bool
    public var hideDockIcon: Bool
    public var keys: KeyMap
    /// Public host of aether-sessiond. Empty keeps shells on this Mac.
    public var sessionHost: String
    /// Kept in the keychain. The JSON files only carry it when the keychain refuses it.
    public var sessionToken: String
    /// WebSocket URL for Cloud. Empty falls back to the older TCP port.
    public var sessionWS: String
    public var confirmClose: ConfirmClose
    public var optionKey: OptionKey
    public var shellExit: ShellExit
    /// Ask before pasting several lines into a shell that would run each one.
    public var warnMultilinePaste: Bool
    /// The size ⌘0 goes back to. The Font slider sets it.
    public var baseFontSize: Double
    /// A command has to run at least this long before it posts a notification.
    public var notifyAfterSeconds: Double
    /// Local or Cloud. Turning Cloud off keeps the account above so it can come back.
    public var cloudEnabled: Bool
    /// Name of a color theme, built in or imported. See Themes.
    public var themeName: String = "Aether"
    /// 0 leaves colors as the theme has them. 1 forces full contrast against the glass behind the text.
    public var minimumContrast: Double = 0.25
    /// Empty uses SF Mono, then Menlo.
    public var fontFamily: String = ""
    /// Multiplier on the font's natural line height.
    public var lineHeight: Double = 1.0
    public var cursorShape: CursorShape = .bar
    public var cursorBlink: Bool = false
    public var scrollbackLines: Int = 10_000
    public var bell: BellStyle = .visual
    public var copyOnSelect: Bool = false
    /// Share of the screen the dropdown covers, top to bottom.
    public var dropdownHeight: Double = 0.44
    public var dropdownHideOnFocusLoss: Bool = true
    /// Prompt marks, command notifications, and titles from zsh, bash, and fish. See ShellIntegration.
    public var shellIntegration: Bool = true
    /// Save each pane's text and show it again, above a new prompt, after Aether restarts.
    public var restoreContents: Bool = true
    /// Draw terminal text with Metal. Panes fall back to CoreGraphics when Metal is missing or its shaders fail to compile.
    /// Off by default: SwiftTerm's Metal path measured no faster than CoreGraphics and used more CPU per frame.
    public var gpuRendering: Bool = false
    /// Where ⌘-clicked file paths open.
    public var editor: EditorChoice = .automatic

    public static let currentVersion = 2

    public init(
        shade: Double = 0.24,
        glass: GlassStyle = .regular,
        text: TextTone = .light,
        fontSize: Double = 13,
        cornerRadius: Double = 20,
        gap: Double = 6,
        snapWindows: Bool = true,
        focusRest: FocusRest = .dim,
        blurAmount: Double = 0.55,
        notifyOnFinish: Bool = true,
        checkForUpdates: Bool = false,
        dropdownEnabled: Bool = true,
        hideDockIcon: Bool = false,
        keys: KeyMap = .standard,
        sessionHost: String = "",
        sessionToken: String = "",
        sessionWS: String = "",
        confirmClose: ConfirmClose = .whenBusy,
        optionKey: OptionKey = .characters,
        shellExit: ShellExit = .close,
        warnMultilinePaste: Bool = true,
        baseFontSize: Double = 13,
        notifyAfterSeconds: Double = 10,
        cloudEnabled: Bool? = nil
    ) {
        self.shade = shade
        self.glass = glass
        self.text = text
        self.fontSize = fontSize
        self.cornerRadius = cornerRadius
        self.gap = gap
        self.snapWindows = snapWindows
        self.focusRest = focusRest
        self.blurAmount = blurAmount
        self.notifyOnFinish = notifyOnFinish
        self.checkForUpdates = checkForUpdates
        self.dropdownEnabled = dropdownEnabled
        self.hideDockIcon = hideDockIcon
        self.keys = keys.filled()
        self.sessionHost = sessionHost
        self.sessionToken = sessionToken
        self.sessionWS = sessionWS
        self.confirmClose = confirmClose
        self.optionKey = optionKey
        self.shellExit = shellExit
        self.warnMultilinePaste = warnMultilinePaste
        self.baseFontSize = baseFontSize
        self.notifyAfterSeconds = notifyAfterSeconds
        self.cloudEnabled = cloudEnabled ?? !(sessionHost.isEmpty && sessionWS.isEmpty)
    }

    /// Each field falls back on its own, so one bad value in config.json does not throw away the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        shade = field(.shade, 0.24)
        glass = field(.glass, GlassStyle.regular)
        text = field(.text, TextTone.light)
        fontSize = field(.fontSize, 13.0)
        cornerRadius = field(.cornerRadius, 20.0)
        gap = field(.gap, 6.0)
        snapWindows = field(.snapWindows, true)
        focusRest = field(.focusRest, FocusRest.dim)
        blurAmount = field(.blurAmount, 0.55)
        notifyOnFinish = field(.notifyOnFinish, true)
        checkForUpdates = field(.checkForUpdates, false)
        dropdownEnabled = field(.dropdownEnabled, true)
        hideDockIcon = field(.hideDockIcon, false)
        keys = field(.keys, KeyMap.standard).filled()
        sessionHost = field(.sessionHost, "")
        sessionToken = field(.sessionToken, "")
        sessionWS = field(.sessionWS, "")
        confirmClose = field(.confirmClose, ConfirmClose.whenBusy)
        optionKey = field(.optionKey, OptionKey.characters)
        shellExit = field(.shellExit, ShellExit.close)
        warnMultilinePaste = field(.warnMultilinePaste, true)
        baseFontSize = field(.baseFontSize, 13.0)
        notifyAfterSeconds = field(.notifyAfterSeconds, 10.0)
        cloudEnabled = field(.cloudEnabled, !(sessionHost.isEmpty && sessionWS.isEmpty))
        themeName = field(.themeName, "Aether")
        minimumContrast = field(.minimumContrast, 0.25)
        fontFamily = field(.fontFamily, "")
        lineHeight = field(.lineHeight, 1.0)
        cursorShape = field(.cursorShape, CursorShape.bar)
        cursorBlink = field(.cursorBlink, false)
        scrollbackLines = field(.scrollbackLines, 10_000)
        bell = field(.bell, BellStyle.visual)
        copyOnSelect = field(.copyOnSelect, false)
        dropdownHeight = field(.dropdownHeight, 0.44)
        dropdownHideOnFocusLoss = field(.dropdownHideOnFocusLoss, true)
        shellIntegration = field(.shellIntegration, true)
        restoreContents = field(.restoreContents, true)
        gpuRendering = field(.gpuRendering, false)
        editor = field(.editor, EditorChoice.automatic)
        clamp()
    }

    public mutating func clamp() {
        shade = Layout.clamp(shade, 0, 0.82)
        blurAmount = Layout.clamp(blurAmount, 0, 1)
        fontSize = Layout.clamp(fontSize, 10, 24)
        baseFontSize = Layout.clamp(baseFontSize, 10, 24)
        notifyAfterSeconds = max(0, notifyAfterSeconds.isFinite ? notifyAfterSeconds : 10)
        cornerRadius = Layout.clamp(cornerRadius, 8, 32)
        gap = Layout.clamp(gap, 2, 22)
        minimumContrast = Layout.clamp(minimumContrast, 0, 1)
        lineHeight = Layout.clamp(lineHeight, 0.8, 2.0)
        scrollbackLines = min(max(scrollbackLines, 0), 1_000_000)
        dropdownHeight = Layout.clamp(dropdownHeight, 0.2, 1.0)
    }
}
