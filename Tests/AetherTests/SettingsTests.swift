import Foundation
import Testing
@testable import AetherKit

@Test func missingGlassDefaultsToRegular() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(settings.glass == .regular)
    #expect(settings.focusRest == .dim)
    #expect(settings.blurAmount == 0.55)
    #expect(settings.checkForUpdates == false)
    #expect(settings.notifyOnFinish)
}

@Test func locatedPathKeepsTheLineNumber() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("note.txt")
    try Data("hi".utf8).write(to: file)
    let found = PathOpener.locate("note.txt:12:3", cwd: directory.path)
    #expect(found?.url.path == file.path)
    #expect(found?.line == 12)
    let web = PathOpener.locate("https://example.com", cwd: directory.path)
    #expect(web?.url.absoluteString == "https://example.com")
    #expect(PathOpener.locate("missing.swift", cwd: directory.path) == nil)
    try? FileManager.default.removeItem(at: directory)
}
