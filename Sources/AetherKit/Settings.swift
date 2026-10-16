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

public struct Settings: Codable, Equatable, Sendable {
    public var shade: Double
    public var glass: GlassStyle
    public var text: TextTone
    public var fontSize: Double
    public var cornerRadius: Double
    public var gap: Double
    public var snapWindows: Bool
    public var focusRest: FocusRest
    public var notifyOnFinish: Bool
    public var dropdownEnabled: Bool
    public var hideDockIcon: Bool
    public var keys: KeyMap
    /// Public host of aether-sessiond. Empty keeps shells on this Mac.
    public var sessionHost: String
    public var sessionToken: String
    /// WebSocket URL for Cloud. Empty falls back to the older TCP port.
    public var sessionWS: String

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
        notifyOnFinish: Bool = true,
        dropdownEnabled: Bool = true,
        hideDockIcon: Bool = false,
        keys: KeyMap = .standard,
        sessionHost: String = "",
        sessionToken: String = "",
        sessionWS: String = ""
    ) {
        self.shade = shade
        self.glass = glass
        self.text = text
        self.fontSize = fontSize
        self.cornerRadius = cornerRadius
        self.gap = gap
        self.snapWindows = snapWindows
        self.focusRest = focusRest
        self.notifyOnFinish = notifyOnFinish
        self.dropdownEnabled = dropdownEnabled
        self.hideDockIcon = hideDockIcon
        self.keys = keys.filled()
        self.sessionHost = sessionHost
        self.sessionToken = sessionToken
        self.sessionWS = sessionWS
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shade = try container.decodeIfPresent(Double.self, forKey: .shade) ?? 0.24
        glass = try container.decodeIfPresent(GlassStyle.self, forKey: .glass) ?? .regular
        text = try container.decodeIfPresent(TextTone.self, forKey: .text) ?? .light
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 20
        gap = try container.decodeIfPresent(Double.self, forKey: .gap) ?? 10
        snapWindows = try container.decodeIfPresent(Bool.self, forKey: .snapWindows) ?? true
        focusRest = try container.decodeIfPresent(FocusRest.self, forKey: .focusRest) ?? .dim
        notifyOnFinish = try container.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? true
        dropdownEnabled = try container.decodeIfPresent(Bool.self, forKey: .dropdownEnabled) ?? true
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        keys = (try container.decodeIfPresent(KeyMap.self, forKey: .keys) ?? .standard).filled()
        sessionHost = try container.decodeIfPresent(String.self, forKey: .sessionHost) ?? ""
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        sessionWS = try container.decodeIfPresent(String.self, forKey: .sessionWS) ?? ""
        clamp()
    }

    public mutating func clamp() {
        shade = Layout.clamp(shade, 0, 0.82)
        fontSize = Layout.clamp(fontSize, 10, 24)
        cornerRadius = Layout.clamp(cornerRadius, 8, 32)
        gap = Layout.clamp(gap, 4, 22)
    }
}
