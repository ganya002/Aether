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

public struct Settings: Codable, Equatable, Sendable {
    public var shade: Double
    public var glass: GlassStyle
    public var text: TextTone
    public var fontSize: Double
    public var cornerRadius: Double
    public var gap: Double
    public var snapWindows: Bool

    public static let currentVersion = 1

    public init(
        shade: Double = 0.24,
        glass: GlassStyle = .clear,
        text: TextTone = .light,
        fontSize: Double = 13,
        cornerRadius: Double = 20,
        gap: Double = 10,
        snapWindows: Bool = true
    ) {
        self.shade = shade
        self.glass = glass
        self.text = text
        self.fontSize = fontSize
        self.cornerRadius = cornerRadius
        self.gap = gap
        self.snapWindows = snapWindows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shade = try container.decodeIfPresent(Double.self, forKey: .shade) ?? 0.24
        glass = try container.decodeIfPresent(GlassStyle.self, forKey: .glass) ?? .clear
        text = try container.decodeIfPresent(TextTone.self, forKey: .text) ?? .light
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 20
        gap = try container.decodeIfPresent(Double.self, forKey: .gap) ?? 10
        snapWindows = try container.decodeIfPresent(Bool.self, forKey: .snapWindows) ?? true
        clamp()
    }

    public mutating func clamp() {
        shade = Layout.clamp(shade, 0, 0.82)
        fontSize = Layout.clamp(fontSize, 10, 24)
        cornerRadius = Layout.clamp(cornerRadius, 8, 32)
        gap = Layout.clamp(gap, 4, 22)
    }
}
