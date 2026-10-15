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
}

/// Control-Command-grave, swallowed by the system so it works from any app.
@MainActor
enum HotkeyCenter {
    static var onFire: (@MainActor () -> Void)?
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var installed = false

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

    static func setEnabled(_ enabled: Bool) {
        if !enabled {
            if let hotKey {
                UnregisterEventHotKey(hotKey)
                self.hotKey = nil
            }
            return
        }
        guard hotKey == nil else { return }
        let identity = EventHotKeyID(signature: OSType(0x4165_7468), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Grave),
            UInt32(controlKey | cmdKey),
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
