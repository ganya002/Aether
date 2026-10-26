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

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
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

    public static let currentVersion = 2

    public init(
        shade: Double = 0.24,
        glass: GlassStyle = .regular,
        text: TextTone = .light,
        fontSize: Double = 13,
        cornerRadius: Double = 20,
        gap: Double = 10,
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
        self.cloudEnabled = cloudEnabled ?? !sessionHost.isEmpty
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
        gap = field(.gap, 10.0)
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
        cloudEnabled = field(.cloudEnabled, !sessionHost.isEmpty)
        clamp()
    }

    public mutating func clamp() {
        shade = Layout.clamp(shade, 0, 0.82)
        blurAmount = Layout.clamp(blurAmount, 0, 1)
        fontSize = Layout.clamp(fontSize, 10, 24)
        baseFontSize = Layout.clamp(baseFontSize, 10, 24)
        notifyAfterSeconds = max(0, notifyAfterSeconds.isFinite ? notifyAfterSeconds : 10)
        cornerRadius = Layout.clamp(cornerRadius, 8, 32)
        gap = Layout.clamp(gap, 4, 22)
    }
}
