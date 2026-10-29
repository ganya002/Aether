import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AetherKit

@Suite struct UserConfigTests {
    @Test func commentsBlankLinesAndWhitespaceAreSkipped() {
        let config = UserConfig.parse("""
        # a comment
           # indented comment

          font-size   =   15
        gap=10\r
        shade = 0.4   # trailing comment
        """)
        #expect(config.problems.isEmpty)
        let settings = config.applied(to: Settings())
        #expect(settings.fontSize == 15)
        #expect(settings.baseFontSize == 15)
        #expect(settings.gap == 10)
        #expect(settings.shade == 0.4)
        #expect(config.sources == ["font-size": 4, "gap": 5, "shade": 6])
    }

    @Test func quotesAreStripped() {
        #expect(UserConfig.unquote(#" "Menlo"  "#) == "Menlo")
        #expect(UserConfig.unquote(" 'a # b' # note") == "a # b")
        #expect(UserConfig.unquote(#" "open"#) == nil)
        #expect(UserConfig.unquote("plain#hash") == "plain#hash")
        let config = UserConfig.parse(#"glass = "clear""#)
        #expect(config.applied(to: Settings()).glass == .clear)
    }

    @Test func theLastDuplicateWins() {
        let config = UserConfig.parse("gap = 4\ngap = 12\n")
        #expect(config.applied(to: Settings()).gap == 12)
        #expect(config.sources["gap"] == 2)
    }

    @Test func badLinesAreReportedAndSkipped() {
        let config = UserConfig.parse("""
        fontsize = 14
        gap
        gap = wide
        font-size = 40
        cursor-blink = maybe
        glass = frosty
        = 3
        title = "unclosed
        corner-radius = 12
        """)
        #expect(config.problems.map(\.line) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(config.applied(to: Settings()).cornerRadius == 12)
        #expect(config.sources == ["corner-radius": 9])
    }

    @Test func errorMessagesSuggestTheNearestKey() {
        let problems = UserConfig.parse("fontsize = 14\nfnot-size = 14\ncursor-shape = blok\n").problems.map(\.description)
        #expect(problems[0] == "config line 1: unknown key `fontsize` — did you mean `font-size`?")
        #expect(problems[1] == "config line 2: unknown key `fnot-size` — did you mean `font-size`?")
        #expect(problems[2] == "config line 3: cursor-shape: `blok` is not one of block, underline, bar — did you mean `block`?")
        #expect(UserConfig.parse("font-size = 40").problems.first?.message == "font-size: 40 is outside 10 to 24")
        #expect(UserConfig.parse("zzzzzzzz = 1").problems.first?.message == "unknown key `zzzzzzzz`")
    }

    @Test func everySettingMaps() {
        let config = UserConfig.parse("""
        theme = dracula
        font-size = 16
        line-height = 1.2
        glass = clear
        text-tone = automatic
        shade = 0.3
        minimum-contrast = 0.5
        cursor-shape = underline
        cursor-blink = true
        unfocused-panes = blur
        blur-amount = 0.2
        corner-radius = 14
        gap = 3
        snap-windows = no
        option-as-meta = left
        shell-exit = keep
        warn-multiline-paste = off
        copy-on-select = yes
        bell = none
        scrollback = 5000
        shell-integration = false
        notify-on-finish = false
        notify-after = 30
        confirm-close = when-busy
        hide-dock-icon = true
        check-for-updates = true
        dropdown = false
        dropdown-height = 0.6
        dropdown-hide-on-focus-loss = false
        """)
        #expect(config.problems.isEmpty, "\(config.problems)")
        let s = config.applied(to: Settings())
        #expect(s.themeName == "Dracula")
        #expect(s.fontSize == 16 && s.lineHeight == 1.2 && s.glass == .clear && s.text == .automatic)
        #expect(s.shade == 0.3 && s.minimumContrast == 0.5 && s.cursorShape == .underline && s.cursorBlink)
        #expect(s.focusRest == .blur && s.blurAmount == 0.2 && s.cornerRadius == 14 && s.gap == 3 && !s.snapWindows)
        #expect(s.optionKey == .leftMeta && s.shellExit == .keep && !s.warnMultilinePaste && s.copyOnSelect && s.bell == BellStyle.none)
        #expect(s.scrollbackLines == 5000 && !s.shellIntegration && !s.notifyOnFinish && s.notifyAfterSeconds == 30)
        #expect(s.confirmClose == .whenBusy && s.hideDockIcon && s.checkForUpdates && !s.dropdownEnabled)
        #expect(s.dropdownHeight == 0.6 && !s.dropdownHideOnFocusLoss)
        #expect(UserConfig.parse("option-as-meta = true").applied(to: Settings()).optionKey == .meta)
    }

    @Test func emptyValueLeavesTheSettingAlone() {
        let config = UserConfig.parse("font-family =\ngap = ")
        #expect(config.problems.isEmpty)
        #expect(config.sources.isEmpty)
    }

    @Test func restoringKeepsTheWindowsValues() {
        var window = Settings()
        window.gap = 9
        window.themeName = "Nord"
        let config = UserConfig.parse("gap = 3\nkeybind = cmd+t=split_right")
        var effective = config.applied(to: window)
        #expect(effective.gap == 3)
        // The window changes something the file does not set.
        effective.shade = 0.5
        let saved = config.restoring(effective, from: window)
        #expect(saved.gap == 9)
        #expect(saved.shade == 0.5)
        #expect(saved.themeName == "Nord")
        #expect(saved.keys == window.keys)
    }

    @Test func keybindsParse() throws {
        let tab = try Keybind.parse("cmd+shift+t=new_tab")
        #expect(tab.action == .newTab)
        #expect(tab.chord.key == "t")
        #expect(tab.chord.flags == [.command, .shift])
        #expect(tab.chord.keyCode == UInt16(kVK_ANSI_T))
        #expect(try Keybind.parse(" ctrl + opt + left = focus-left ").action == .focusLeft)
        #expect(try Keybind.parse("cmd+1=focusPane1").action == .focusPane1)
        #expect(try Keybind.parse("cmd+5=focus_pane_5").action == .focusPane5)
        let plus = try Keybind.parse("cmd++=font_up")
        #expect(plus.chord.key == "=" && plus.chord.keyCode == UInt16(kVK_ANSI_Equal))
        #expect(try Keybind.parse("cmd+==font_up").chord.key == "=")
        #expect(try Keybind.parse("cmd+k=unbind").action == nil)
        #expect(try Keybind.parse("cmd+return=fill").chord.key == "\r")
        #expect(throws: ConfigError.self) { try Keybind.parse("t=new_tab") }
        #expect(throws: ConfigError.self) { try Keybind.parse("hyper+t=new_tab") }
        #expect(throws: ConfigError.self) { try Keybind.parse("cmd+t") }
        #expect(throws: ConfigError.self) { try Keybind.parse("cmd+t=new_tabb") }
        #expect(throws: ConfigError.self) { try Keybind.parse("cmd+escape=new_tab") }
        let problem = UserConfig.parse("keybind = cmd+t=new_tabb").problems.first?.message
        #expect(problem == "keybind: unknown action `new_tabb` — did you mean `new_tab`?")
    }

    @Test func keybindsMapOntoTheKeyMap() {
        let config = UserConfig.parse("keybind = cmd+t=split_right\nkeybind = cmd+k=unbind")
        let keys = config.applied(to: Settings()).keys
        #expect(keys.chord(.splitRight).key == "t")
        // ⌘T belonged to New terminal. It lets go.
        #expect(keys.chord(.newPane).key.isEmpty)
        #expect(keys.chord(.clearBuffer).key.isEmpty)
        #expect(config.sources == ["keybind:splitRight": 1])
    }

    @Test func defaultChordsRoundTrip() throws {
        for action in AppAction.allCases where !action.defaultChord.key.isEmpty {
            let parsed = try Keybind.parse("\(Keybind.text(action.defaultChord))=\(action.configName)")
            #expect(parsed.action == action)
            #expect(parsed.chord.sameKeys(as: action.defaultChord), "\(action)")
        }
    }

    @Test func theTemplateIsAllCommentsAndCoversEveryKey() {
        let template = UserConfig.template()
        let config = UserConfig.parse(template)
        #expect(config.problems.isEmpty)
        #expect(config.entries.isEmpty)
        for key in ConfigKey.all where key.name != "keybind" {
            #expect(template.contains("# \(key.name) = "))
        }
        // Uncommenting every line gives a valid config that changes nothing.
        let uncommented = template.split(separator: "\n").map { $0.range(of: #"^# [a-z-]+ = "#, options: .regularExpression) != nil ? String($0.dropFirst(2)) : String($0) }
        let live = UserConfig.parse(uncommented.joined(separator: "\n"))
        #expect(live.problems.isEmpty, "\(live.problems)")
        #expect(live.applied(to: Settings()) == Settings())
    }

    @Test func pathFollowsXDG() {
        #expect(UserConfigCenter.fileURL(environment: [:], home: "/Users/me").path == "/Users/me/.config/aether/config")
        #expect(UserConfigCenter.fileURL(environment: ["XDG_CONFIG_HOME": "/x"], home: "/Users/me").path == "/x/aether/config")
    }

    @Test func caseNames() {
        #expect(snake("focusPane1") == "focus_pane_1")
        #expect(kebab("whenBusy") == "when-busy")
        #expect(AppAction.selectLastOutput.configName == "select_last_output")
    }
}
