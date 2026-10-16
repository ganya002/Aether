import Foundation
import Testing
@testable import AetherKit

@Test func newerBuildOfferPointsAtTheZip() throws {
    let json = """
    {"tag_name":"build-abc123","assets":[{"name":"Aether.app.zip","browser_download_url":"https://example.com/Aether.app.zip"}]}
    """.data(using: .utf8)!
    let offer = ReleaseFeed.offer(from: json, localCommit: "111111")
    #expect(offer?.commit == "abc123")
    #expect(offer?.zip.absoluteString == "https://example.com/Aether.app.zip")
}

@Test func sameCommitIsNotAnUpdate() throws {
    let json = """
    {"tag_name":"build-abc123","assets":[{"name":"Aether.app.zip","browser_download_url":"https://example.com/Aether.app.zip"}]}
    """.data(using: .utf8)!
    #expect(ReleaseFeed.offer(from: json, localCommit: "ABC123") == nil)
}

@Test func devBuildDoesNotNagForEveryRelease() throws {
    let json = """
    {"tag_name":"build-abc1234","assets":[{"name":"Aether.app.zip","browser_download_url":"https://example.com/Aether.app.zip"}]}
    """.data(using: .utf8)!
    #expect(ReleaseFeed.offer(from: json, localCommit: "dev") == nil)
    #expect(ReleaseFeed.offer(from: json, localCommit: "") == nil)
}

@Test func resetRestoresTheOriginalShortcut() {
    let changed = KeyMap.standard.assigning(AppAction.newWindow.defaultChord, to: .newPane)
    let restored = changed.restoring(.newWindow)
    #expect(restored.chord(.newWindow) == AppAction.newWindow.defaultChord)
    #expect(restored.chord(.newPane).key.isEmpty)
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

@Test func releaseWithoutTheAppZipIsIgnored() throws {
    let json = """
    {"tag_name":"build-abc123","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"}]}
    """.data(using: .utf8)!
    #expect(ReleaseFeed.offer(from: json, localCommit: "111111") == nil)
}
