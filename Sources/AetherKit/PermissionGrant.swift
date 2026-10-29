import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import AppTrackingTransparency
import Contacts
import CoreBluetooth
import CoreLocation
import EventKit
import Intents
import IOKit.hid
import MusicKit
import Photos
import Speech
import UserNotifications

/// Walks through every macOS permission Aether can ask for, one dialog at a time.
/// Each step is a no-op besides the prompt: no camera session, no contact fetch, no location stream.
@MainActor
enum PermissionGrant {
    enum ID: String, CaseIterable, Sendable {
        case notifications
        case camera
        case microphone
        case photos
        case contacts
        case calendars
        case reminders
        case location
        case bluetooth
        case speech
        case appleMusic
        case tracking
        case focus
        case screenRecording
        case accessibility
        case inputMonitoring
        case postEvents
        case appleEvents
        case localNetwork
        case desktop
        case documents
        case downloads
        case volumes
        case fullDiskAccess
    }

    enum Access: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
        case settings
    }

    struct Item: Equatable, Sendable {
        var id: ID
        var title: String
        var settingsPane: String?
    }

    static let catalog: [Item] = [
        Item(id: .notifications, title: "Notifications"),
        Item(id: .camera, title: "Camera", settingsPane: "Privacy_Camera"),
        Item(id: .microphone, title: "Microphone", settingsPane: "Privacy_Microphone"),
        Item(id: .photos, title: "Photos", settingsPane: "Privacy_Photos"),
        Item(id: .contacts, title: "Contacts", settingsPane: "Privacy_Contacts"),
        Item(id: .calendars, title: "Calendars", settingsPane: "Privacy_Calendars"),
        Item(id: .reminders, title: "Reminders", settingsPane: "Privacy_Reminders"),
        Item(id: .location, title: "Location", settingsPane: "Privacy_LocationServices"),
        Item(id: .bluetooth, title: "Bluetooth", settingsPane: "Privacy_Bluetooth"),
        Item(id: .speech, title: "Speech recognition", settingsPane: "Privacy_SpeechRecognition"),
        Item(id: .appleMusic, title: "Apple Music"),
        Item(id: .tracking, title: "Tracking"),
        Item(id: .focus, title: "Focus"),
        Item(id: .screenRecording, title: "Screen recording", settingsPane: "Privacy_ScreenCapture"),
        Item(id: .accessibility, title: "Accessibility", settingsPane: "Privacy_Accessibility"),
        Item(id: .inputMonitoring, title: "Input monitoring", settingsPane: "Privacy_ListenEvent"),
        Item(id: .postEvents, title: "Sending keystrokes", settingsPane: "Privacy_ListenEvent"),
        Item(id: .appleEvents, title: "Automation", settingsPane: "Privacy_Automation"),
        Item(id: .localNetwork, title: "Local network", settingsPane: "Privacy_LocalNetwork"),
        Item(id: .desktop, title: "Desktop folder", settingsPane: "Privacy_FilesAndFolders"),
        Item(id: .documents, title: "Documents folder", settingsPane: "Privacy_FilesAndFolders"),
        Item(id: .downloads, title: "Downloads folder", settingsPane: "Privacy_FilesAndFolders"),
        Item(id: .volumes, title: "Volumes", settingsPane: "Privacy_FilesAndFolders"),
        Item(id: .fullDiskAccess, title: "Full Disk Access", settingsPane: "Privacy_AllFiles"),
    ]

    static func status(of id: ID) -> Access {
        if remembered.contains(id) { return .granted }
        switch id {
        case .notifications:
            return notificationAccess
        case .camera:
            return mapAV(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return mapAV(AVCaptureDevice.authorizationStatus(for: .audio))
        case .photos:
            return mapPhotos(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case .contacts:
            return mapContacts(CNContactStore.authorizationStatus(for: .contacts))
        case .calendars:
            return mapEvent(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return mapEvent(EKEventStore.authorizationStatus(for: .reminder))
        case .location:
            return mapLocation(CLLocationManager().authorizationStatus)
        case .bluetooth:
            return mapBluetooth(CBManager.authorization)
        case .speech:
            return mapSpeech(SFSpeechRecognizer.authorizationStatus())
        case .appleMusic:
            return mapMusic(MusicAuthorization.currentStatus)
        case .tracking:
            return mapTracking(ATTrackingManager.trackingAuthorizationStatus)
        case .focus:
            return mapFocus(INFocusStatusCenter.default.authorizationStatus)
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? .granted : .notDetermined
        case .postEvents:
            return IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted ? .granted : .notDetermined
        case .appleEvents:
            return .notDetermined
        case .localNetwork:
            return .notDetermined
        case .desktop, .documents, .downloads, .volumes:
            return .notDetermined
        case .fullDiskAccess:
            return FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db") ? .granted : .settings
        }
    }

    private static var remembered: Set<ID> = []

    static func missing() -> [Item] {
        catalog.filter { status(of: $0.id) != .granted }
    }

    static func missingNow() async -> [Item] {
        await refreshNotifications()
        return missing()
    }

    static func settingsURL(pane: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    private static var notificationAccess: Access = .notDetermined

    private static func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationAccess = .granted
        case .denied: notificationAccess = .denied
        default: notificationAccess = .notDetermined
        }
    }

    /// Confirm, then ask for every permission that is not already granted.
    static func present(from window: NSWindow? = nil) {
        Task { @MainActor in
            let left = await missingNow()
            await present(left, from: window)
        }
    }

    private static func present(_ left: [Item], from window: NSWindow?) async {
        if left.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Aether already has every permission"
            alert.informativeText = "macOS is not holding any of the permissions Aether can ask for."
            alert.addButton(withTitle: "OK")
            await run(alert, from: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Give All Permissions?"
        alert.informativeText = "Aether will ask macOS for each permission it does not have yet, one dialog at a time. Allow them. A few, like Full Disk Access, open System Settings because macOS has no in-app prompt.\n\nStill needed: " + left.map(\.title).joined(separator: ", ") + "."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard await run(alert, from: window) == .alertFirstButtonReturn else { return }
        await walk(left, from: window)
    }

    static func walk(_ items: [Item], from window: NSWindow? = nil) async {
        for item in items {
            let now = status(of: item.id)
            if now == .granted { continue }
            if now == .settings || (now != .notDetermined && item.settingsPane != nil && item.id != .localNetwork) {
                continue
            }
            await request(item.id)
        }
        let leftover = await missingNow()
        if leftover.isEmpty {
            let done = NSAlert()
            done.messageText = "Aether has every permission"
            done.informativeText = "Commands in the terminal can use the camera, the LAN, your files, and the rest."
            done.addButton(withTitle: "OK")
            await run(done, from: window)
            return
        }
        let panes = leftover.compactMap(\.settingsPane)
        if leftover.count == 1, let pane = leftover[0].settingsPane, let url = settingsURL(pane: pane) {
            NSWorkspace.shared.open(url)
        } else if !panes.isEmpty {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
        let wrap = NSAlert()
        wrap.messageText = leftover.count == 1 ? "One permission still needs you" : "\(leftover.count) permissions still need you"
        wrap.informativeText = leftover.map(\.title).joined(separator: ", ") + ".\n\nTurn Aether on in System Settings, then run Give All Permissions again."
        wrap.addButton(withTitle: "OK")
        await run(wrap, from: window)
    }

    @discardableResult
    private static func run(_ alert: NSAlert, from window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible, window.attachedSheet == nil {
            return await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
                alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }

    static func request(_ id: ID) async {
        switch id {
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshNotifications()
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .photos:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in cont.resume() }
            }
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .location:
            await LocationAsker.ask()
        case .bluetooth:
            await BluetoothAsker.ask()
        case .speech:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
        case .appleMusic:
            _ = await MusicAuthorization.request()
        case .tracking:
            _ = await ATTrackingManager.requestTrackingAuthorization()
        case .focus:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                INFocusStatusCenter.default.requestAuthorization { _ in cont.resume() }
            }
        case .screenRecording:
            if CGRequestScreenCaptureAccess() { remembered.insert(.screenRecording) }
        case .accessibility:
            if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
                remembered.insert(.accessibility)
            }
        case .inputMonitoring:
            if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { remembered.insert(.inputMonitoring) }
        case .postEvents:
            if IOHIDRequestAccess(kIOHIDRequestTypePostEvent) { remembered.insert(.postEvents) }
        case .appleEvents:
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"System Events\" to get name")?.executeAndReturnError(&error)
            var finder: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Finder\" to get name")?.executeAndReturnError(&finder)
            if error == nil && finder == nil { remembered.insert(.appleEvents) }
        case .localNetwork:
            LocalNetworkAccess.start()
            remembered.insert(.localNetwork)
        case .desktop:
            rememberFolder(.desktop, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
        case .documents:
            rememberFolder(.documents, FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        case .downloads:
            rememberFolder(.downloads, FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        case .volumes:
            rememberFolder(.volumes, URL(fileURLWithPath: "/Volumes", isDirectory: true))
            if let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) {
                for url in mounts where url.path != "/" && !url.path.hasPrefix("/System") {
                    _ = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.nameKey], options: .skipsHiddenFiles)
                }
            }
        case .fullDiskAccess:
            _ = FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        }
    }

    private static func rememberFolder(_ id: ID, _ url: URL) {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.nameKey], options: .skipsHiddenFiles)
            remembered.insert(id)
        } catch {
            return
        }
    }

    private static func mapAV(_ status: AVAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapPhotos(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized, .limited: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapContacts(_ status: CNAuthorizationStatus) -> Access {
        switch status {
        case .authorized, .limited: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapEvent(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess, .writeOnly, .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapLocation(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .authorizedAlways, .authorized, .authorizedWhenInUse: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapBluetooth(_ status: CBManagerAuthorization) -> Access {
        switch status {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapSpeech(_ status: SFSpeechRecognizerAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapMusic(_ status: MusicAuthorization.Status) -> Access {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapTracking(_ status: ATTrackingManager.AuthorizationStatus) -> Access {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func mapFocus(_ status: INFocusStatusAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}

private final class LocationAsker: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<Void, Never>?

    static func ask() async {
        let asker = LocationAsker()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            asker.cont = cont
            asker.manager.delegate = asker
            let status = asker.manager.authorizationStatus
            if status == .notDetermined {
                asker.manager.requestWhenInUseAuthorization()
            } else {
                cont.resume()
                asker.cont = nil
            }
        }
        withExtendedLifetime(asker) {}
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        cont?.resume()
        cont = nil
    }
}

private final class BluetoothAsker: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var manager: CBCentralManager?
    private var cont: CheckedContinuation<Void, Never>?

    static func ask() async {
        let asker = BluetoothAsker()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            asker.cont = cont
            if CBManager.authorization != .notDetermined {
                cont.resume()
                asker.cont = nil
                return
            }
            asker.manager = CBCentralManager(
                delegate: asker,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
        withExtendedLifetime(asker) {}
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        cont?.resume()
        cont = nil
    }
}
