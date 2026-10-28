import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AetherKit

@Test func commandKClearsAndTheLauncherMovesToCommandP() {
    #expect(AppAction.clearBuffer.defaultChord.key == "k")
    #expect(AppAction.launch.defaultChord.key == "p")
    #expect(AppAction.launch.defaultChord.modifiers == NSEvent.ModifierFlags.command.rawValue)
}

@Test func savedLauncherOnCommandKMovesToCommandP() throws {
    var old = KeyMap.standard
    old.chords[AppAction.clearBuffer.rawValue] = nil
    old.chords[AppAction.launch.rawValue] = KeyChord(
        key: "k",
        modifiers: NSEvent.ModifierFlags.command.rawValue,
        keyCode: UInt16(kVK_ANSI_K),
        follow: AppAction.equalize.rawValue
    )
    let data = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(KeyMap.self, from: data).filled()
    #expect(decoded.chord(.launch).key == "p")
    #expect(decoded.chord(.launch).keyCode == UInt16(kVK_ANSI_P))
    #expect(decoded.chord(.launch).follow == AppAction.equalize.rawValue)
    #expect(decoded.chord(.clearBuffer).key == "k")
}

@Test func customizedLauncherStaysWhereItIs() {
    var old = KeyMap.standard
    old.chords[AppAction.clearBuffer.rawValue] = nil
    old.chords[AppAction.launch.rawValue] = KeyChord(
        key: "j",
        modifiers: NSEvent.ModifierFlags.command.rawValue,
        keyCode: UInt16(kVK_ANSI_J)
    )
    let filled = old.filled()
    #expect(filled.chord(.launch).key == "j")
    #expect(filled.chord(.clearBuffer).key == "k")
}

@Test func launcherStaysOnCommandKWhenCommandPIsTaken() {
    var old = KeyMap.standard
    let command = NSEvent.ModifierFlags.command.rawValue
    old.chords[AppAction.clearBuffer.rawValue] = nil
    old.chords[AppAction.launch.rawValue] = KeyChord(key: "k", modifiers: command, keyCode: UInt16(kVK_ANSI_K))
    old.chords[AppAction.find.rawValue] = KeyChord(key: "p", modifiers: command, keyCode: UInt16(kVK_ANSI_P))
    let filled = old.filled()
    #expect(filled.chord(.launch).key == "k")
    #expect(filled.chord(.clearBuffer).key.isEmpty)
}

@Test func badSettingsFieldsFallBackOneByOne() throws {
    let json = """
    {"shade": "lots", "glass": "frosted", "fontSize": 16, "gap": null, "snapWindows": 3,
     "confirmClose": "always", "optionKey": "sideways", "notifyAfterSeconds": 30,
     "keys": {"chords": {"newWindow": {"key": 5}, "newPane": {"key": "y", "modifiers": 1048576, "keyCode": 16}}}}
    """
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.shade == 0.24)
    #expect(settings.glass == .regular)
    #expect(settings.fontSize == 16)
    #expect(settings.gap == 6)
    #expect(settings.snapWindows)
    #expect(settings.confirmClose == .always)
    #expect(settings.optionKey == .characters)
    #expect(settings.notifyAfterSeconds == 30)
    #expect(settings.keys.chord(.newPane).key == "y")
    #expect(settings.keys.chord(.newWindow) == AppAction.newWindow.defaultChord)
}

@Test func newSettingsHaveSafeDefaults() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(settings.confirmClose == .whenBusy)
    #expect(settings.optionKey == .characters)
    #expect(settings.shellExit == .close)
    #expect(settings.warnMultilinePaste)
    #expect(settings.baseFontSize == 13)
    #expect(settings.notifyAfterSeconds == 10)
    #expect(settings.gap == 6)
}

@Test func configThatIsNotJSONIsRejected() {
    #expect(ConfigStore.decode(Data("{ not json".utf8)) == nil)
    #expect(ConfigStore.decode(Data("[1, 2]".utf8)) == nil)
    #expect(ConfigStore.decode(Data("{\"fontSize\": 15}".utf8))?.fontSize == 15)
}

@Test func directoryFromAnotherHostIsIgnored() {
    let local = ["Gabbos-MacBook-Pro.local"]
    #expect(System.normalizeDirectory("file://build-server/home/me", localHosts: local) == nil)
    #expect(System.normalizeDirectory("file://build-server.example.com/srv", localHosts: local) == nil)
    #expect(System.normalizeDirectory("file:///tmp/work", localHosts: local) == "/tmp/work")
    #expect(System.normalizeDirectory("file://localhost/tmp/work", localHosts: local) == "/tmp/work")
    #expect(System.normalizeDirectory("file://Gabbos-MacBook-Pro.local/Users/me", localHosts: local) == "/Users/me")
    #expect(System.normalizeDirectory("file://gabbos-macbook-pro/Users/me%20too", localHosts: local) == "/Users/me too")
    #expect(System.normalizeDirectory("/Users/me", localHosts: local) == "/Users/me")
    #expect(System.normalizeDirectory("relative", localHosts: local) == nil)
}

@Test func editingKeysMatchTerminalApp() {
    let left = UInt16(kVK_LeftArrow)
    let right = UInt16(kVK_RightArrow)
    let delete = UInt16(kVK_Delete)
    #expect(EditingKeys.sequence(keyCode: left, flags: .option, optionIsMeta: false) == [0x1b, 0x62])
    #expect(EditingKeys.sequence(keyCode: right, flags: .option, optionIsMeta: false) == [0x1b, 0x66])
    #expect(EditingKeys.sequence(keyCode: delete, flags: .option, optionIsMeta: false) == [0x1b, 0x7f])
    #expect(EditingKeys.sequence(keyCode: left, flags: .command, optionIsMeta: false) == [0x01])
    #expect(EditingKeys.sequence(keyCode: right, flags: .command, optionIsMeta: false) == [0x05])
    #expect(EditingKeys.sequence(keyCode: delete, flags: .command, optionIsMeta: false) == [0x15])
    #expect(EditingKeys.sequence(keyCode: left, flags: .command, optionIsMeta: false, alternateScreen: true) == nil)
    #expect(EditingKeys.sequence(keyCode: delete, flags: .command, optionIsMeta: false, alternateScreen: true) == nil)
    #expect(EditingKeys.sequence(keyCode: left, flags: .option, optionIsMeta: false, alternateScreen: true) == [0x1b, 0x62])
    // SwiftTerm already handles Option as Meta. Other chords keep their menu meaning.
    #expect(EditingKeys.sequence(keyCode: left, flags: .option, optionIsMeta: true) == nil)
    #expect(EditingKeys.sequence(keyCode: left, flags: [.command, .option], optionIsMeta: false) == nil)
    #expect(EditingKeys.sequence(keyCode: left, flags: [.command, .shift], optionIsMeta: false) == nil)
    #expect(EditingKeys.sequence(keyCode: UInt16(kVK_ANSI_A), flags: .option, optionIsMeta: false) == nil)
}

@Test func multiLinePasteWarnsOnlyWithoutBracketedPaste() {
    let script = "make\nmake deploy\n"
    #expect(PasteGuard.shouldWarn(script, bracketed: false, enabled: true))
    #expect(!PasteGuard.shouldWarn(script, bracketed: true, enabled: true))
    #expect(!PasteGuard.shouldWarn(script, bracketed: false, enabled: false))
    #expect(!PasteGuard.shouldWarn("just one line", bracketed: false, enabled: true))
    #expect(PasteGuard.shouldWarn("rm -rf build\n", bracketed: false, enabled: true))
    #expect(PasteGuard.lineCount(script) == 2)
    #expect(PasteGuard.oneLine(script) == "make make deploy")
}

@Test func finishPhraseCarriesStatusAndTime() {
    #expect(FinishNotifier.phrase(command: "cargo build", elapsed: 48, exitCode: 0) == "✓ cargo build · 48s")
    #expect(FinishNotifier.phrase(command: "cargo build", elapsed: 48, exitCode: 101) == "✗ cargo build failed (exit 101)")
    #expect(FinishNotifier.phrase(command: "make", elapsed: 75, exitCode: nil) == "make finished · 1m 15s")
}

@Test func onlyAPlainShellClosesOnACleanExit() {
    let settings = Settings()
    #expect(PaneController.closesOnExit(code: 0, command: nil, settings: settings))
    #expect(!PaneController.closesOnExit(code: 1, command: nil, settings: settings))
    #expect(!PaneController.closesOnExit(code: nil, command: nil, settings: settings))
    #expect(!PaneController.closesOnExit(code: 0, command: "make", settings: settings))
    var keep = settings
    keep.shellExit = .keep
    #expect(!PaneController.closesOnExit(code: 0, command: nil, settings: keep))
}

@Test @MainActor func shellEnvironmentKeepsTheUsersOwnVariables() {
    let env = PaneController.shellEnvironment(pane: "p1")
    let keys = env.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
    #expect(env.contains("TERM=xterm-256color"))
    #expect(env.contains("TERM_PROGRAM=Aether"))
    #expect(env.contains("AETHER_PANE=p1"))
    #expect(keys.contains("SHELL"))
    #expect(keys.contains("TMPDIR"))
    #expect(keys.contains("PATH"))
    #expect(!keys.contains("TERM_SESSION_ID"))
    #expect(keys.filter { $0 == "TERM" }.count == 1)
    #expect(keys.filter { $0 == "TERM_PROGRAM" }.count == 1)
}
