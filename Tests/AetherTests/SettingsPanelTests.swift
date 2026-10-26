import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AetherKit

private func chord(_ key: String, _ flags: NSEvent.ModifierFlags, _ code: Int) -> KeyChord {
    KeyChord(key: key, modifiers: flags.rawValue, keyCode: UInt16(code))
}

@Test func settingsValuesReadTheWayPeopleSayThem() {
    #expect(SettingsFormat.percent(0.24) == "24 %")
    #expect(SettingsFormat.percent(0) == "0 %")
    #expect(SettingsFormat.percent(0.824) == "82 %")
    #expect(SettingsFormat.points(13) == "13 pt")
    #expect(SettingsFormat.points(13.5) == "13.5 pt")
    #expect(SettingsFormat.points(20.0001) == "20 pt")
    #expect(SettingsFormat.multiplier(1) == "1.0×")
    #expect(SettingsFormat.multiplier(1.2) == "1.2×")
    #expect(SettingsFormat.multiplier(1.25) == "1.25×")
    #expect(SettingsFormat.multiplier(0.8) == "0.8×")
}

@Test func settingsDurationsAndScrollback() {
    #expect(SettingsFormat.duration(1) == "1 second")
    #expect(SettingsFormat.duration(10) == "10 seconds")
    #expect(SettingsFormat.duration(60) == "1 minute")
    #expect(SettingsFormat.duration(300) == "5 minutes")
    #expect(SettingsFormat.duration(90) == "90 seconds")
    let us = Locale(identifier: "en_US")
    #expect(SettingsFormat.scrollback(1_000, locale: us) == "1,000 lines")
    #expect(SettingsFormat.scrollback(10_000, locale: us) == "10,000 lines")
    #expect(SettingsFormat.scrollback(1_000_000, locale: us) == "Unlimited")
    #expect(SettingsFormat.scrollbackChoices.last == SettingsFormat.unlimitedScrollback)
}

@Test func settingsChoicesKeepAnOddValueFromConfig() {
    #expect(SettingsFormat.choices([1, 10, 100], including: 10) == [1, 10, 100])
    #expect(SettingsFormat.choices([1, 10, 100], including: 50) == [1, 10, 50, 100])
    #expect(SettingsFormat.choices([5.0, 10, 30], including: 0) == [0, 5, 10, 30])
}

@Test func settingsSlidersSnapToTheirStep() {
    #expect(SettingsFormat.snap(1.2349, step: 0.05) == 1.25)
    #expect(SettingsFormat.snap(13.3, step: 0.5) == 13.5)
    #expect(SettingsFormat.snap(0.2449, step: 0.01) == 0.24)
    #expect(SettingsFormat.snap(7, step: 0) == 7)
}

@Test func settingsResetKeepsTheCloudAccount() {
    var settings = Settings(shade: 0.6, fontSize: 18, sessionHost: "cloud.example", sessionToken: "secret", sessionWS: "wss://cloud.example/ws", cloudEnabled: true)
    settings.themeName = "Nord"
    settings.keys = settings.keys.assigning(chord("j", .command, kVK_ANSI_J), to: .splitRight)
    let fresh = settings.resetKeepingCloud()
    #expect(fresh.shade == Settings().shade)
    #expect(fresh.fontSize == 13)
    #expect(fresh.themeName == "Aether")
    #expect(fresh.keys == KeyMap.standard)
    #expect(fresh.sessionHost == "cloud.example")
    #expect(fresh.sessionToken == "secret")
    #expect(fresh.sessionWS == "wss://cloud.example/ws")
    #expect(fresh.cloudEnabled)
}

@Test func settingsTabsHaveSixSymbolsInOrder() {
    #expect(SettingsTab.allCases.map(\.title) == ["General", "Appearance", "Terminal", "Windows", "Keys", "Cloud"])
    for tab in SettingsTab.allCases {
        #expect(SettingsTab(identifier: tab.identifier) == tab)
        #expect(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) != nil)
    }
}

@Test func reservedChordsAreRefused() {
    #expect(ShortcutRules.verdict(chord("\t", .command, kVK_Tab), for: .launch) == .reserved("switches apps"))
    #expect(ShortcutRules.verdict(chord(" ", .command, kVK_Space), for: .launch) == .reserved("opens Spotlight"))
    #expect(ShortcutRules.verdict(chord("q", [.command, .control], kVK_ANSI_Q), for: .quit) == .reserved("locks the screen"))
    #expect(ShortcutRules.verdict(chord("h", .command, kVK_ANSI_H), for: .find) == .reserved("hides Aether"))
    #expect(ShortcutRules.verdict(chord("3", [.command, .shift], kVK_ANSI_3), for: .find) == .reserved("takes a screenshot"))
}

@Test func commandQIsOnlyForQuit() {
    let commandQ = chord("q", .command, kVK_ANSI_Q)
    #expect(ShortcutRules.verdict(commandQ, for: .quit) == .fine)
    #expect(ShortcutRules.verdict(commandQ, for: .splitRight) == .reserved("quits Aether"))
}

@Test func optionOnlyChordsWarnButOthersAreFine() {
    #expect(ShortcutRules.verdict(chord("d", .option, kVK_ANSI_D), for: .splitRight) == .optionOnly)
    #expect(ShortcutRules.verdict(chord("d", [.option, .shift], kVK_ANSI_D), for: .splitRight) == .optionOnly)
    #expect(ShortcutRules.verdict(chord("d", [.option, .command], kVK_ANSI_D), for: .splitRight) == .fine)
    #expect(ShortcutRules.verdict(chord("d", .control, kVK_ANSI_D), for: .splitRight) == .fine)
    #expect(ShortcutRules.verdict(KeyChord.unassigned, for: .splitRight) == .fine)
    for action in AppAction.allCases {
        #expect(ShortcutRules.verdict(action.defaultChord, for: action) == .fine, "default for \(action) is refused")
    }
}

@Test func everyActionHasOneGroupAndSectionsKeepMenuOrder() {
    let sections = ShortcutGroup.sections(matching: "", keys: .standard)
    #expect(sections.map(\.group) == ShortcutGroup.allCases)
    let listed = sections.flatMap(\.actions)
    #expect(listed.count == AppAction.allCases.count)
    #expect(Set(listed) == Set(AppAction.allCases))
    #expect(ShortcutGroup.of(.splitDown) == .windows)
    #expect(ShortcutGroup.of(.growLeft) == .resize)
    #expect(ShortcutGroup.of(.findNext) == .find)
    #expect(ShortcutGroup.of(.dropdown) == .app)
    #expect(ShortcutGroup.allCases.map(\.title) == ["Windows & Panes", "Layout", "Focus", "Resize", "Text", "Find", "App"])
}

@Test func shortcutSearchMatchesNamesGroupsAndKeys() {
    let split = ShortcutGroup.sections(matching: "split", keys: .standard)
    #expect(split.flatMap(\.actions) == [.splitRight, .splitDown, .equalize])
    let focus = ShortcutGroup.sections(matching: "focus", keys: .standard).flatMap(\.actions)
    #expect(focus == [.focusLeft, .focusRight, .focusUp, .focusDown])
    let byKey = ShortcutGroup.sections(matching: "⇧⌘D", keys: .standard).flatMap(\.actions)
    #expect(byKey == [.splitDown])
    let spoken = ShortcutGroup.sections(matching: "command shift d", keys: .standard).flatMap(\.actions)
    #expect(spoken.contains(.splitDown))
    #expect(!spoken.contains(.splitRight))
    #expect(ShortcutGroup.sections(matching: "nothing like this", keys: .standard).isEmpty)
}

@Test func spokenShortcutsReadForVoiceOver() {
    #expect(AppAction.splitDown.defaultChord.spoken == "Command Shift D")
    #expect(AppAction.dropdown.defaultChord.spoken == "Control Command Grave Accent")
    #expect(AppAction.focusLeft.defaultChord.spoken == "Option Command Left Arrow")
    #expect(KeyChord.unassigned.spoken == "No shortcut")
}

@Test func holdersFindWhoLosesAShortcut() {
    let map = KeyMap.standard
    #expect(map.holders(of: AppAction.splitRight.defaultChord, except: .newPane) == [.splitRight])
    #expect(map.holders(of: AppAction.splitRight.defaultChord, except: .splitRight).isEmpty)
    #expect(map.holders(of: chord("j", .command, kVK_ANSI_J), except: .splitRight).isEmpty)
    #expect(map.holders(of: .unassigned, except: .splitRight).isEmpty)
}

@Test func shortcutNotesSayWhatChanged() {
    let commandD = AppAction.splitRight.defaultChord
    let displaced = ShortcutNote(kind: .assigned(commandD, displaced: [.splitRight], optionOnly: false), undo: .standard)
    #expect(displaced.message == "⌘D was Split right — now unassigned")
    #expect(!displaced.isWarning)
    let two = ShortcutNote(kind: .assigned(commandD, displaced: [.splitRight, .fill], optionOnly: false))
    #expect(two.message == "⌘D was Split right and Fill window — now unassigned")
    let option = ShortcutNote(kind: .assigned(chord("d", .option, kVK_ANSI_D), displaced: [], optionOnly: true))
    #expect(option.isWarning)
    #expect(option.message.contains("⌥D"))
    let refused = ShortcutNote(kind: .reserved(chord("\t", .command, kVK_Tab), "switches apps"))
    #expect(refused.message == "⌘⇥ switches apps, so Aether can't use it")
    #expect(refused.isWarning)
    #expect(ShortcutNote(kind: .unassigned(.splitDown)).message == "Split down has no shortcut now")
}

@Test func chainingOffersOnlyWhatFinishCanRun() {
    #expect(AppAction.splitRight.canChain)
    #expect(!AppAction.focusLeft.canChain)
    #expect(!AppAction.chainTargets.contains(.quit))
    #expect(AppAction.chainTargets.contains(.equalize))
}

@MainActor
@Test func settingsIsANormalWindowThatStaysOpen() throws {
    _ = NSApplication.shared
    let controller = SettingsController()
    let window = try #require(controller.window)
    #expect(window.styleMask.contains(.titled))
    #expect(window.styleMask.contains(.closable))
    #expect(window.styleMask.contains(.resizable))
    #expect(!window.isReleasedWhenClosed)
    #expect(window.toolbar != nil)
    #expect(window.minSize.width == window.maxSize.width)
}
