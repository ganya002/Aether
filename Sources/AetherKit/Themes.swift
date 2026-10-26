import Foundation

/// An sRGB color with components from 0 to 1.
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    /// Reads `#rrggbb`, `rrggbb`, `#rgb` or `rgb`.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Relative luminance as WCAG defines it.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        return RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(1, 1, 1)
}

/// The colors a theme gives the terminal for one kind of backdrop.
public struct Palette: Equatable, Sendable {
    public var foreground: RGB
    /// The background the theme was drawn on. The glass stays, this only tints the shade.
    public var background: RGB
    public var cursor: RGB
    public var selection: RGB
    /// The 16 ANSI colors, normal 0–7 then bright 8–15.
    public var ansi: [RGB]

    public init(foreground: RGB, background: RGB, cursor: RGB? = nil, selection: RGB? = nil, ansi: [RGB]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor ?? foreground
        self.selection = selection ?? foreground.mixed(with: background, 0.7)
        var colors = Array(ansi.prefix(16))
        while colors.count < 16 { colors.append(Palette.xterm[colors.count]) }
        self.ansi = colors
    }

    /// Made for a dark background, so for light text.
    public var isDark: Bool { background.luminance < 0.25 }

    init(_ foreground: String, _ background: String, cursor: String, selection: String, _ ansi: String) {
        self.init(
            foreground: RGB(hex: foreground)!,
            background: RGB(hex: background)!,
            cursor: RGB(hex: cursor),
            selection: RGB(hex: selection),
            ansi: ansi.split(separator: " ").map { RGB(hex: String($0))! }
        )
    }

    static let xterm: [RGB] = "000000 cd0000 00cd00 cdcd00 0000ee cd00cd 00cdcd e5e5e5 7f7f7f ff0000 00ff00 ffff00 5c5cff ff00ff 00ffff ffffff"
        .split(separator: " ").map { RGB(hex: String($0))! }
}

/// A color theme. Some come in two variants, one for light text on dark glass and one for dark text on light glass.
/// The pane uses whichever matches the text tone, and the other when the theme has only one.
public struct Theme: Equatable, Sendable {
    public var name: String
    /// For light text, over dark glass.
    public var dark: Palette?
    /// For dark text, over light glass.
    public var light: Palette?

    public init(name: String, dark: Palette?, light: Palette?) {
        self.name = name
        self.dark = dark
        self.light = light
    }

    /// Files and single-variant themes land in the slot their background belongs to.
    public init(name: String, palette: Palette) {
        self.init(name: name, dark: palette.isDark ? palette : nil, light: palette.isDark ? nil : palette)
    }

    public func palette(for tone: TextTone) -> Palette {
        if tone == .dark {
            return light ?? dark!
        }
        return dark ?? light!
    }

    /// True when the theme has a variant drawn for this tone.
    public func fits(_ tone: TextTone) -> Bool {
        tone == .dark ? light != nil : dark != nil
    }
}

public enum Themes {
    public static let defaultName = "Aether"

    public static let builtIn: [Theme] = {
        let aetherDark = Palette(
            "f2f7fa", "000000", cursor: "f2f7fa", selection: "3a4250",
            "a3acba ff8787 7ee787 f5d76e 74b9ff d9a3ff 5fd7e6 d6dde6 b9c1cd ff9c9c a3f0a8 ffe58f a4d0ff e8c4ff 8ae8f2 ffffff"
        )
        let aetherLight = Palette(
            "15171c", "ffffff", cursor: "15171c", selection: "c9d4e3",
            "1d2128 b0101f 0c5f27 6b4b00 0a4fc2 7a2bb8 075e6e 3c434e 2c323b 8c0d18 0c5824 573d00 083f9c 61228f 054b58 23282f"
        )
        let solarizedANSI = "073642 dc322f 859900 b58900 268bd2 d33682 2aa198 eee8d5 002b36 cb4b16 586e75 657b83 839496 6c71c4 93a1a1 fdf6e3"
        let solarizedDark = Palette("839496", "002b36", cursor: "93a1a1", selection: "073642", solarizedANSI)
        let solarizedLight = Palette("657b83", "fdf6e3", cursor: "586e75", selection: "eee8d5", solarizedANSI)
        let gruvboxDark = Palette(
            "ebdbb2", "282828", cursor: "ebdbb2", selection: "504945",
            "282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2"
        )
        let gruvboxLight = Palette(
            "3c3836", "fbf1c7", cursor: "3c3836", selection: "d5c4a1",
            "fbf1c7 cc241d 98971a d79921 458588 b16286 689d6a 7c6f64 928374 9d0006 79740e b57614 076678 8f3f71 427b58 3c3836"
        )
        let oneDark = Palette(
            "abb2bf", "282c34", cursor: "528bff", selection: "3e4451",
            "282c34 e06c75 98c379 e5c07b 61afef c678dd 56b6c2 abb2bf 5c6370 e06c75 98c379 e5c07b 61afef c678dd 56b6c2 ffffff"
        )
        let oneLight = Palette(
            "383a42", "fafafa", cursor: "526fff", selection: "e5e5e6",
            "383a42 e45649 50a14f c18401 4078f2 a626a4 0184bc a0a1a7 696c77 e45649 50a14f c18401 4078f2 a626a4 0184bc fafafa"
        )
        let tokyoNight = Palette(
            "c0caf5", "1a1b26", cursor: "c0caf5", selection: "33467c",
            "15161e f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff a9b1d6 414868 f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff c0caf5"
        )
        let tokyoDay = Palette(
            "3760bf", "e1e2e7", cursor: "3760bf", selection: "b7c1e3",
            "e9e9ed f52a65 587539 8c6c3e 2e7de9 9854f1 007197 6172b0 a1a6c5 f52a65 587539 8c6c3e 2e7de9 9854f1 007197 3760bf"
        )
        let mocha = Palette(
            "cdd6f4", "1e1e2e", cursor: "f5e0dc", selection: "585b70",
            "45475a f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 bac2de 585b70 f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 a6adc8"
        )
        let latte = Palette(
            "4c4f69", "eff1f5", cursor: "dc8a78", selection: "acb0be",
            "5c5f77 d20f39 40a02b df8e1d 1e66f5 ea76cb 179299 acb0be 6c6f85 d20f39 40a02b df8e1d 1e66f5 ea76cb 179299 bcc0cc"
        )
        let githubDark = Palette(
            "e6edf3", "0d1117", cursor: "2f81f7", selection: "264f78",
            "484f58 ff7b72 3fb950 d29922 58a6ff bc8cff 39c5cf b1bac4 6e7681 ffa198 56d364 e3b341 79c0ff d2a8ff 56d4dd ffffff"
        )
        let githubLight = Palette(
            "1f2328", "ffffff", cursor: "0969da", selection: "add6ff",
            "24292f cf222e 116329 4d2d00 0969da 8250df 1b7c83 6e7781 57606a a40e26 1a7f37 633c01 218bff a475f9 3192aa 8c959f"
        )
        let dracula = Palette(
            "f8f8f2", "282a36", cursor: "f8f8f2", selection: "44475a",
            "21222c ff5555 50fa7b f1fa8c bd93f9 ff79c6 8be9fd f8f8f2 6272a4 ff6e6e 69ff94 ffffa5 d6acff ff92df a4ffff ffffff"
        )
        let nord = Palette(
            "d8dee9", "2e3440", cursor: "d8dee9", selection: "434c5e",
            "3b4252 bf616a a3be8c ebcb8b 81a1c1 b48ead 88c0d0 e5e9f0 4c566a bf616a a3be8c ebcb8b 81a1c1 b48ead 8fbcbb eceff4"
        )
        return [
            Theme(name: "Aether", dark: aetherDark, light: aetherLight),
            Theme(name: "Catppuccin", dark: mocha, light: latte),
            Theme(name: "Catppuccin Latte", palette: latte),
            Theme(name: "Catppuccin Mocha", palette: mocha),
            Theme(name: "Dracula", palette: dracula),
            Theme(name: "GitHub", dark: githubDark, light: githubLight),
            Theme(name: "GitHub Dark", palette: githubDark),
            Theme(name: "GitHub Light", palette: githubLight),
            Theme(name: "Gruvbox", dark: gruvboxDark, light: gruvboxLight),
            Theme(name: "Gruvbox Dark", palette: gruvboxDark),
            Theme(name: "Gruvbox Light", palette: gruvboxLight),
            Theme(name: "Nord", palette: nord),
            Theme(name: "One", dark: oneDark, light: oneLight),
            Theme(name: "One Dark", palette: oneDark),
            Theme(name: "One Light", palette: oneLight),
            Theme(name: "Solarized", dark: solarizedDark, light: solarizedLight),
            Theme(name: "Solarized Dark", palette: solarizedDark),
            Theme(name: "Solarized Light", palette: solarizedLight),
            Theme(name: "Tokyo Night", dark: tokyoNight, light: tokyoDay),
            Theme(name: "Tokyo Night Day", palette: tokyoDay),
        ]
    }()

    /// Where imported themes live: `.itermcolors` files and Ghostty theme files.
    public static func directory() -> URL {
        System.supportDirectory().appendingPathComponent("themes", isDirectory: true)
    }

    /// Built-in names with Aether first, then imported ones. An imported theme with a built-in name replaces it.
    public static func names() -> [String] {
        let imported = userThemes().map(\.name)
        let builtIns = builtIn.map(\.name).filter { !imported.contains($0) }
        return builtIns + imported.filter { !builtIns.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func named(_ name: String) -> Theme? {
        if let imported = userThemes().first(where: { $0.name == name }) { return imported }
        return builtIn.first { $0.name == name }
    }

    /// The named theme, or Aether when it is gone.
    public static func resolve(_ name: String) -> Theme {
        named(name) ?? builtIn[0]
    }

    // MARK: Import

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var stamp: Date?
        var themes: [Theme] = []
    }

    private static let cache = Cache()

    /// Rereads the folder only when it changed.
    public static func userThemes() -> [Theme] {
        let folder = directory()
        let stamp = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if stamp == cache.stamp { return cache.themes }
        cache.stamp = stamp
        cache.themes = load(from: folder)
        return cache.themes
    }

    static func load(from folder: URL) -> [Theme] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var themes: [Theme] = []
        for file in names.sorted() where !file.hasPrefix(".") {
            let url = folder.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), data.count < 512 * 1024 else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let palette: Palette?
            if url.pathExtension.lowercased() == "itermcolors" {
                palette = parseITerm(data)
            } else {
                palette = String(data: data, encoding: .utf8).flatMap(parseGhostty)
            }
            if let palette, !themes.contains(where: { $0.name == name }) {
                themes.append(Theme(name: name, palette: palette))
            }
        }
        return themes
    }

    /// An iTerm2 color preset: a property list of dictionaries with "Red Component" and friends.
    public static func parseITerm(_ data: Data) -> Palette? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func color(_ key: String) -> RGB? {
            guard let entry = plist[key] as? [String: Any] else { return nil }
            func component(_ name: String) -> Double? {
                (entry["\(name) Component"] as? NSNumber)?.doubleValue
            }
            guard let r = component("Red"), let g = component("Green"), let b = component("Blue") else { return nil }
            return RGB(r, g, b)
        }
        let ansi = (0..<16).map { color("Ansi \($0) Color") }
        guard ansi.contains(where: { $0 != nil }) || color("Foreground Color") != nil else { return nil }
        return assemble(
            foreground: color("Foreground Color"),
            background: color("Background Color"),
            cursor: color("Cursor Color"),
            selection: color("Selection Color"),
            ansi: ansi
        )
    }

    /// A Ghostty theme: `palette = 0=#1d1f21`, `foreground = ...`, `background = ...`,
    /// `cursor-color = ...`, `selection-background = ...`. Other keys are ignored.
    public static func parseGhostty(_ text: String) -> Palette? {
        var ansi = [RGB?](repeating: nil, count: 16)
        var values: [String: RGB] = [:]
        var found = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index), let color = RGB(hex: parts[1]) else { continue }
                ansi[index] = color
                found = true
            } else if let color = RGB(hex: value) {
                values[key] = color
                if ["foreground", "background"].contains(key) { found = true }
            }
        }
        guard found else { return nil }
        return assemble(
            foreground: values["foreground"],
            background: values["background"],
            cursor: values["cursor-color"],
            selection: values["selection-background"],
            ansi: ansi
        )
    }

    private static func assemble(foreground: RGB?, background: RGB?, cursor: RGB?, selection: RGB?, ansi: [RGB?]) -> Palette {
        let background = background ?? (foreground.map { $0.luminance > 0.4 ? RGB.black : RGB.white } ?? .black)
        let fallback = background.luminance < 0.25 ? builtIn[0].dark! : builtIn[0].light!
        let foreground = foreground ?? fallback.foreground
        return Palette(
            foreground: foreground,
            background: background,
            cursor: cursor,
            selection: selection,
            ansi: ansi.enumerated().map { $0.element ?? fallback.ansi[$0.offset] }
        )
    }
}

/// Everything a pane paints for one set of settings, worked out away from AppKit.
public struct TerminalLook: Equatable, Sendable {
    /// The theme's colors after minimum contrast.
    public var palette: Palette
    /// Tints the shade over the glass: the theme's own background when it was drawn for this tone, black or white otherwise.
    public var veil: RGB
    public var shade: Double
    public var selection: RGB
    public var selectionAlpha: Double

    /// Reduce Transparency keeps at least this much shade over the glass.
    public static let opaqueShadeFloor = 0.6
    /// Increase Contrast asks for at least this much minimum contrast.
    public static let boostedContrast = 0.8

    public init(theme: Theme, tone: TextTone, shade: Double, minimumContrast: Double,
                reduceTransparency: Bool = false, increaseContrast: Bool = false) {
        let tone: TextTone = tone == .dark ? .dark : .light
        let source = theme.palette(for: tone)
        let fits = theme.fits(tone)
        veil = fits ? source.background : (tone == .dark ? .white : .black)
        self.shade = reduceTransparency ? max(shade, Self.opaqueShadeFloor) : shade
        let minimum = increaseContrast ? max(minimumContrast, Self.boostedContrast) : minimumContrast
        let backdrop = Contrast.backdrop(tone: tone, shade: self.shade, veil: veil)
        palette = Contrast.adjust(source, against: backdrop, target: Contrast.target(minimum: minimum))
        if fits, theme.name != Themes.defaultName {
            selection = source.selection
            selectionAlpha = 0.6
        } else {
            selection = palette.foreground
            selectionAlpha = 0.22
        }
    }

    public init(settings: Settings, tone: TextTone, reduceTransparency: Bool = false, increaseContrast: Bool = false) {
        self.init(theme: Themes.resolve(settings.themeName), tone: tone, shade: settings.shade,
                  minimumContrast: settings.minimumContrast,
                  reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
    }
}

/// Keeps text readable on glass. The backdrop is a guess: the shade veil over a mid-gray desktop,
/// the worst case behind clear glass. Colors that fall short get pushed toward white or black.
public enum Contrast {
    /// WCAG contrast ratio, from 1 to 21.
    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The setting's 0...1 as a ratio. 0 leaves colors alone, 1 asks for 7:1.
    public static func target(minimum: Double) -> Double {
        1 + 6 * min(max(minimum, 0), 1)
    }

    /// The veil at `shade` over a mid-gray desktop. `veil` defaults to black for light text and white for dark text.
    public static func backdrop(tone: TextTone, shade: Double, veil: RGB? = nil) -> RGB {
        let veil = veil ?? (tone == .dark ? RGB.white : RGB.black)
        return RGB(0.5, 0.5, 0.5).mixed(with: veil, shade)
    }

    /// The closest color to `color` that reaches `target` against `backdrop`, moving toward white or black,
    /// whichever needs the smaller step. When neither gets there, the end with more contrast wins.
    public static func adjust(_ color: RGB, against backdrop: RGB, target: Double) -> RGB {
        guard target > 1, ratio(color, backdrop) < target else { return color }
        func reach(_ end: RGB) -> (amount: Double, color: RGB)? {
            guard ratio(end, backdrop) >= target else { return nil }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if ratio(color.mixed(with: end, mid), backdrop) >= target { high = mid } else { low = mid }
            }
            return (high, color.mixed(with: end, high))
        }
        let lighter = reach(.white), darker = reach(.black)
        switch (lighter, darker) {
        case let (l?, d?): return l.amount <= d.amount ? l.color : d.color
        case let (l?, nil): return l.color
        case let (nil, d?): return d.color
        default: return ratio(.white, backdrop) >= ratio(.black, backdrop) ? .white : .black
        }
    }

    public static func adjust(_ palette: Palette, against backdrop: RGB, target: Double) -> Palette {
        var result = palette
        result.foreground = adjust(palette.foreground, against: backdrop, target: target)
        result.cursor = adjust(palette.cursor, against: backdrop, target: target)
        result.ansi = palette.ansi.map { adjust($0, against: backdrop, target: target) }
        return result
    }
}
