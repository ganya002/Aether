import Foundation
import Testing
@testable import AetherKit

private let itermSample = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Ansi 0 Color</key>
    <dict>
        <key>Color Space</key><string>sRGB</string>
        <key>Red Component</key><real>0.0</real>
        <key>Green Component</key><real>0.0</real>
        <key>Blue Component</key><real>0.0</real>
    </dict>
    <key>Ansi 1 Color</key>
    <dict>
        <key>Red Component</key><real>1</real>
        <key>Green Component</key><real>0.0</real>
        <key>Blue Component</key><real>0.0</real>
    </dict>
    <key>Ansi 15 Color</key>
    <dict>
        <key>Red Component</key><real>1</real>
        <key>Green Component</key><real>1</real>
        <key>Blue Component</key><real>1</real>
    </dict>
    <key>Foreground Color</key>
    <dict>
        <key>Red Component</key><real>0.8</real>
        <key>Green Component</key><real>0.8</real>
        <key>Blue Component</key><real>0.8</real>
    </dict>
    <key>Background Color</key>
    <dict>
        <key>Red Component</key><real>0.1</real>
        <key>Green Component</key><real>0.1</real>
        <key>Blue Component</key><real>0.1</real>
    </dict>
    <key>Cursor Color</key>
    <dict>
        <key>Red Component</key><real>0</real>
        <key>Green Component</key><real>1</real>
        <key>Blue Component</key><real>0</real>
    </dict>
</dict>
</plist>
"""

private let ghosttySample = """
# A comment
palette = 0=#1d1f21
palette = 1=#cc6666
palette = 2 = b5bd68
palette = 15=#ffffff
background = #fafafa
foreground = 383a42
cursor-color = #526fff
selection-background = #e5e5e6
font-size = 13
"""

@Test func itermColorsParse() throws {
    let palette = try #require(Themes.parseITerm(Data(itermSample.utf8)))
    #expect(palette.ansi.count == 16)
    #expect(palette.ansi[0] == RGB(0, 0, 0))
    #expect(palette.ansi[1] == RGB(1, 0, 0))
    #expect(palette.ansi[15] == RGB(1, 1, 1))
    #expect(palette.foreground == RGB(0.8, 0.8, 0.8))
    #expect(palette.background == RGB(0.1, 0.1, 0.1))
    #expect(palette.cursor == RGB(0, 1, 0))
    #expect(palette.isDark)
    let theme = Theme(name: "Sample", palette: palette)
    #expect(theme.dark != nil && theme.light == nil)
}

@Test func ghosttyThemeParses() throws {
    let palette = try #require(Themes.parseGhostty(ghosttySample))
    #expect(palette.ansi.count == 16)
    #expect(palette.ansi[0].hex == "#1d1f21")
    #expect(palette.ansi[1].hex == "#cc6666")
    #expect(palette.ansi[2].hex == "#b5bd68")
    #expect(palette.ansi[15].hex == "#ffffff")
    #expect(palette.foreground.hex == "#383a42")
    #expect(palette.background.hex == "#fafafa")
    #expect(palette.cursor.hex == "#526fff")
    #expect(palette.selection.hex == "#e5e5e6")
    #expect(!palette.isDark)
}

@Test func garbageIsNotATheme() {
    #expect(Themes.parseGhostty("font-size = 13\nhello") == nil)
    #expect(Themes.parseITerm(Data("not a plist".utf8)) == nil)
}

@Test func themeFolderLoadsBothFormats() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(itermSample.utf8).write(to: folder.appendingPathComponent("Night.itermcolors"))
    try Data(ghosttySample.utf8).write(to: folder.appendingPathComponent("Day"))
    try Data("nothing".utf8).write(to: folder.appendingPathComponent("notes.txt"))
    let themes = Themes.load(from: folder)
    #expect(themes.map(\.name) == ["Day", "Night"])
    #expect(themes[0].light != nil)
    #expect(themes[1].dark != nil)
}

@Test func builtInThemesAreComplete() {
    #expect(Themes.builtIn.first?.name == Themes.defaultName)
    #expect(Set(Themes.builtIn.map(\.name)).count == Themes.builtIn.count)
    for theme in Themes.builtIn {
        #expect(theme.dark != nil || theme.light != nil, "\(theme.name)")
        for palette in [theme.dark, theme.light].compactMap({ $0 }) {
            #expect(palette.ansi.count == 16, "\(theme.name)")
        }
    }
    for name in ["Aether", "Solarized Dark", "Solarized Light", "Dracula", "Nord", "Gruvbox Dark", "Gruvbox Light",
                 "One Dark", "Tokyo Night", "Catppuccin Mocha", "Catppuccin Latte", "GitHub Light", "GitHub Dark"] {
        #expect(Themes.named(name) != nil, "\(name)")
    }
    #expect(Themes.resolve("No Such Theme").name == "Aether")
}

@Test func pairedThemesFollowTheTone() throws {
    let solarized = try #require(Themes.named("Solarized"))
    #expect(solarized.palette(for: .light).isDark)
    #expect(!solarized.palette(for: .dark).isDark)
    let dracula = try #require(Themes.named("Dracula"))
    #expect(dracula.palette(for: .dark) == dracula.palette(for: .light))
    #expect(!dracula.fits(.dark))
}

@Test func aetherIsReadableOnBothTonesAsShipped() throws {
    let aether = try #require(Themes.named("Aether"))
    let target = Contrast.target(minimum: Settings().minimumContrast)
    for tone in [TextTone.light, .dark] {
        let backdrop = Contrast.backdrop(tone: tone, shade: Settings().shade)
        let palette = aether.palette(for: tone)
        for (index, color) in ([palette.foreground] + palette.ansi).enumerated() {
            #expect(Contrast.ratio(color, backdrop) >= target, "\(tone) color \(index - 1) \(color.hex)")
        }
    }
}

@Test func contrastRatioMatchesWCAG() {
    #expect(abs(Contrast.ratio(.white, .black) - 21) < 0.001)
    #expect(abs(Contrast.ratio(.black, .black) - 1) < 0.001)
    #expect(abs(Contrast.ratio(RGB(hex: "#777777")!, .white) - 4.48) < 0.01)
}

@Test func contrastTargetSpansOffToSevenToOne() {
    #expect(Contrast.target(minimum: 0) == 1)
    #expect(Contrast.target(minimum: 1) == 7)
    #expect(Contrast.target(minimum: 0.5) == 4)
}

@Test func zeroContrastLeavesColorsAlone() {
    let yellow = RGB(hex: "#f1fa8c")!
    let backdrop = Contrast.backdrop(tone: .dark, shade: 0.24)
    #expect(Contrast.adjust(yellow, against: backdrop, target: Contrast.target(minimum: 0)) == yellow)
}

@Test func contrastPushesFaintColorsUntilTheyRead() {
    let backdrop = Contrast.backdrop(tone: .dark, shade: 0.5)
    for hex in ["#f1fa8c", "#ffffff", "#e5c07b", "#8be9fd"] {
        let color = RGB(hex: hex)!
        let fixed = Contrast.adjust(color, against: backdrop, target: 4.5)
        #expect(Contrast.ratio(fixed, backdrop) >= 4.5, "\(hex)")
        #expect(fixed.luminance < color.luminance, "\(hex) should get darker on light glass")
    }
    let dark = Contrast.backdrop(tone: .light, shade: 0.5)
    let blue = RGB(hex: "#268bd2")!
    let fixed = Contrast.adjust(blue, against: dark, target: 4.5)
    #expect(Contrast.ratio(fixed, dark) >= 4.5)
    #expect(fixed.luminance > blue.luminance)
    #expect(fixed.b > fixed.r, "hue survives")
}

@Test func colorsThatAlreadyReadStayPut() {
    let backdrop = Contrast.backdrop(tone: .light, shade: 0.4)
    let white = RGB(1, 1, 1)
    #expect(Contrast.adjust(white, against: backdrop, target: 4.5) == white)
}

@Test func unreachableTargetGoesToTheStrongerEnd() {
    let gray = RGB(0.5, 0.5, 0.5)
    let result = Contrast.adjust(RGB(0.45, 0.45, 0.45), against: gray, target: 21)
    #expect(result == .black)
}

@Test func backdropFollowsTheVeil() {
    #expect(Contrast.backdrop(tone: .light, shade: 0) == RGB(0.5, 0.5, 0.5))
    #expect(Contrast.backdrop(tone: .light, shade: 1) == .black)
    #expect(Contrast.backdrop(tone: .dark, shade: 1) == .white)
}

@Test func lookTintsWithTheThemeOnlyWhenItFitsTheTone() throws {
    let dracula = try #require(Themes.named("Dracula"))
    let onDark = TerminalLook(theme: dracula, tone: .light, shade: 0.24, minimumContrast: 0)
    #expect(onDark.veil.hex == "#282a36")
    #expect(onDark.palette == dracula.dark)
    let onLight = TerminalLook(theme: dracula, tone: .dark, shade: 0.24, minimumContrast: 0.25)
    #expect(onLight.veil == .white)
    let backdrop = Contrast.backdrop(tone: .dark, shade: 0.24)
    for color in onLight.palette.ansi + [onLight.palette.foreground] {
        #expect(Contrast.ratio(color, backdrop) >= Contrast.target(minimum: 0.25) - 0.01, "\(color.hex)")
    }
}

@Test func accessibilityRaisesShadeAndContrast() throws {
    let aether = try #require(Themes.named("Aether"))
    let plain = TerminalLook(theme: aether, tone: .light, shade: 0.1, minimumContrast: 0)
    #expect(plain.shade == 0.1)
    let opaque = TerminalLook(theme: aether, tone: .light, shade: 0.1, minimumContrast: 0, reduceTransparency: true)
    #expect(opaque.shade == TerminalLook.opaqueShadeFloor)
    let boosted = TerminalLook(theme: aether, tone: .dark, shade: 0.24, minimumContrast: 0, increaseContrast: true)
    let backdrop = Contrast.backdrop(tone: .dark, shade: 0.24)
    let target = Contrast.target(minimum: TerminalLook.boostedContrast)
    for color in boosted.palette.ansi {
        #expect(Contrast.ratio(color, backdrop) >= target - 0.01, "\(color.hex)")
    }
}
