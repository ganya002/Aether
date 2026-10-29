import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AetherKit

@Test func resetRestoresTheOriginalShortcut() {
    let changed = KeyMap.standard.assigning(AppAction.newWindow.defaultChord, to: .newPane)
    let restored = changed.restoring(.newWindow)
    #expect(restored.chord(.newWindow) == AppAction.newWindow.defaultChord)
    #expect(restored.chord(.newPane).key.isEmpty)
}

private final class ShortcutProbe: NSObject {
    var fired = false
    @objc func fire(_ sender: Any?) { fired = true }
}

@Test @MainActor func biggerTextShortcutMatchesCommandEquals() {
    let chord = AppAction.fontUp.defaultChord
    #expect(chord.key == "=")
    let probe = ShortcutProbe()
    let item = NSMenuItem(title: "Bigger", action: #selector(ShortcutProbe.fire(_:)), keyEquivalent: chord.key)
    item.keyEquivalentModifierMask = chord.flags
    item.target = probe
    let menu = NSMenu()
    menu.addItem(item)
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "=",
        charactersIgnoringModifiers: "=",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Equal)
    )!
    #expect(menu.performKeyEquivalent(with: event))
}

@Test func savedPlusKeyForBiggerTextBecomesEquals() {
    var map = KeyMap.standard
    map.chords[AppAction.fontUp.rawValue] = KeyChord(
        key: "+",
        modifiers: NSEvent.ModifierFlags.command.rawValue,
        keyCode: UInt16(kVK_ANSI_Equal)
    )
    #expect(map.filled().chord(.fontUp).key == "=")
}

@Test func defaultShortcutsDoNotCollide() {
    var seen: [String: AppAction] = [:]
    for action in AppAction.allCases {
        let chord = action.defaultChord
        guard !chord.key.isEmpty else { continue }
        let id = "\(chord.key)|\(chord.modifiers)"
        if let other = seen[id] {
            Issue.record("\(action) shares \(id) with \(other)")
        }
        seen[id] = action
    }
}

@Test func takingAShortcutClearsTheOtherAction() {
    let taken = KeyMap.standard.assigning(AppAction.newWindow.defaultChord, to: .newPane)
    #expect(taken.chord(.newPane) == AppAction.newWindow.defaultChord)
    #expect(taken.chord(.newWindow).key.isEmpty)
}

@Test func shellQuoteLeavesPlainPathsAlone() {
    #expect(ShellPath.quote("/Users/gabbo/Photo.png") == "/Users/gabbo/Photo.png")
    #expect(ShellPath.quote("/Users/gabbo/My Photos") == "'/Users/gabbo/My Photos'")
    #expect(ShellPath.quote("/tmp/it's") == "'" + "/tmp/it" + "'\\''" + "s'")
}
