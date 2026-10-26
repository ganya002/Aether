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
        let intro = target.insetBy(dx: target.width * 0.022, dy: target.height * 0.028)
        window.alphaValue = 0
        window.setFrame(intro, display: false)
        window.makeKeyAndOrderFront(nil)
        Motion.group(Motion.reveal) {
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Fade and lift the panel until it is gone. `finish` decides whether the
    /// panel is still the one that should disappear.
    static func vaporize(_ window: NSWindow, finish: @escaping () -> Bool = { true }) {
        guard window.isVisible else { return }
        let home = window.frame
        var gone = home.insetBy(dx: home.width * 0.04, dy: home.height * 0.05)
        gone.origin.y += 10
        Motion.group(Motion.close, {
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

enum GlassPanel {
    /// Round the glass and clip it. A square black backing otherwise shows in the corners.
    static func mount(_ glass: NSGlassEffectView, on window: NSWindow, radius: CGFloat) {
        window.isOpaque = false
        window.backgroundColor = .clear
        glass.cornerRadius = radius
        glass.wantsLayer = true
        glass.layer?.cornerRadius = radius
        glass.layer?.masksToBounds = true
        window.contentView = glass
    }
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
    /// The result of the last registration. eventHotKeyExistsErr means another app holds the shortcut.
    private(set) static var status: OSStatus = noErr

    static var takenByAnotherApp: Bool {
        status == OSStatus(eventHotKeyExistsErr)
    }

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

    @discardableResult
    static func apply(enabled: Bool, chord: KeyChord) -> OSStatus {
        if installedEnabled == enabled, installedChord == chord { return status }
        installedEnabled = enabled
        installedChord = chord
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        status = noErr
        // The A key is key code 0, so an empty key is what means "no shortcut".
        guard enabled, !chord.key.isEmpty else { return status }
        let identity = EventHotKeyID(signature: OSType(0x4165_7468), id: 1)
        status = RegisterEventHotKey(
            UInt32(chord.keyCode),
            chord.carbonModifiers,
            identity,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status != noErr { hotKey = nil }
        return status
    }
}

@MainActor
enum FinishNotifier {
    private static let delegate = NotificationRouter()

    static func install() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Asked when the setting is switched on, so the system prompt follows something the user did.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Someone who never touched the setting gets quiet delivery to Notification Center, with no prompt.
    static func requestQuietPermissionIfUndecided() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .provisional]) { _, _ in }
        }
    }

    static func deliver(title: String, body: String, pane: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["pane": pane]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(request)
        }
    }

    /// "✓ cargo build · 48s", or "✗ cargo build failed (exit 101)". Without an exit code there is no mark.
    nonisolated static func phrase(command: String, elapsed: TimeInterval, exitCode: Int32?) -> String {
        let seconds = Int(elapsed.rounded())
        let span = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        guard let exitCode else { return "\(command) finished · \(span)" }
        if exitCode == 0 { return "✓ \(command) · \(span)" }
        return "✗ \(command) failed (exit \(exitCode))"
    }
}

/// Clicking a finished-command notification brings back the pane it came from.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let pane = response.notification.request.content.userInfo["pane"] as? String else { return }
        await MainActor.run {
            AppModel.shared.reveal(pane: pane)
        }
    }
}
