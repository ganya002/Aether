import AppKit
import Foundation
import Testing
@testable import AetherKit

@Test @MainActor func permissionCatalogListsEachKindOnce() {
    let ids = PermissionGrant.catalog.map(\.id)
    #expect(ids.count == PermissionGrant.ID.allCases.count)
    #expect(Set(ids) == Set(PermissionGrant.ID.allCases))
    #expect(Set(PermissionGrant.catalog.map(\.title)).count == ids.count)
}

@Test @MainActor func permissionSettingsPanesMakeSecurityURLs() {
    for item in PermissionGrant.catalog {
        guard let pane = item.settingsPane else { continue }
        let url = PermissionGrant.settingsURL(pane: pane)
        #expect(url != nil, "\(item.title) pane \(pane)")
        #expect(url?.scheme == "x-apple.systempreferences")
        #expect(url?.absoluteString.contains(pane) == true)
    }
}

@Test @MainActor func permissionStatusCanBeReadWithoutPrompting() {
    for id in PermissionGrant.ID.allCases {
        _ = PermissionGrant.status(of: id)
    }
    let missing = PermissionGrant.missing()
    #expect(Set(missing.map(\.id)).isSubset(of: Set(PermissionGrant.ID.allCases)))
}

@Test @MainActor func launcherFindsGiveAllPermissions() {
    let actions = CommandPalette.actions()
    #expect(actions.contains { $0.title == "Give All Permissions" && $0.kind == .action(.giveAllPermissions) })
    for query in ["permissions", "tcc", "privacy", "full disk", "accessibility"] {
        let rows = Launcher.rows(query: query, actions: actions, tools: [], recents: [], hosts: [])
        #expect(rows.contains { $0.kind == .action(.giveAllPermissions) }, "query \(query)")
    }
}

@Test @MainActor func settingsGeneralHasGiveAllPermissions() throws {
    UserDefaults.standard.set("general", forKey: "aether.settings.tab")
    _ = NSApplication.shared
    let controller = SettingsController()
    let window = try #require(controller.window)
    window.layoutIfNeeded()
    #expect(firstButton(titled: "Give All Permissions…", in: window.contentView) != nil)
}

@MainActor
private func firstButton(titled title: String, in view: NSView?) -> NSButton? {
    guard let view else { return nil }
    if let button = view as? NSButton, button.title == title { return button }
    for child in view.subviews {
        if let found = firstButton(titled: title, in: child) { return found }
    }
    return nil
}
