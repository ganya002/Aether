import AppKit
import Carbon.HIToolbox
import Foundation
import UserNotifications

enum GlassMotion {
    static func present(_ window: NSWindow) {
        if window.isVisible, window.alphaValue > 0.95 {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let target = window.frame
        let intro = target.insetBy(dx: target.width * 0.045, dy: target.height * 0.045)
        window.alphaValue = 0
        window.setFrame(intro, display: false)
        window.makeKeyAndOrderFront(nil)
        Motion.group(0.2) {
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Fade and lift the panel until it is gone. `finish` decides whether the
    /// panel is still the one that should disappear.
    static func vaporize(_ window: NSWindow, finish: @escaping () -> Bool = { true }) {
        guard window.isVisible else { return }
        let home = window.frame
        var gone = home.insetBy(dx: home.width * 0.08, dy: home.height * 0.1)
        gone.origin.y += 18
        Motion.group(0.22, {
            window.animator().alphaValue = 0
            window.animator().setFrame(gone, display: true)
        }, done: {
            guard finish() else { return }
            window.orderOut(nil)
            window.setFrame(home, display: false)
            window.alphaValue = 1
        })
    }
}

final class VaporPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Control-Command-grave, swallowed by the system so it works from any app.
@MainActor
enum HotkeyCenter {
    static var onFire: (@MainActor () -> Void)?
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var installed = false
    private static var installedChord: KeyChord?
    private static var installedEnabled = false

    static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotkeyCenter.onFire?()
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    static func apply(enabled: Bool, chord: KeyChord) {
        if installedEnabled == enabled, installedChord == chord { return }
        installedEnabled = enabled
        installedChord = chord
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard enabled, chord.keyCode != 0 else { return }
        let identity = EventHotKeyID(signature: OSType(0x4165_7468), id: 1)
        RegisterEventHotKey(
            UInt32(chord.keyCode),
            chord.carbonModifiers,
            identity,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}

@MainActor
enum FinishNotifier {
    private static var asked = false

    static func deliver(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if asked {
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
                center.add(request)
            }
            return
        }
        asked = true
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}
