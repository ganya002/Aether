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

@Test func releaseWithoutTheAppZipIsIgnored() throws {
    let json = """
    {"tag_name":"build-abc123","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"}]}
    """.data(using: .utf8)!
    #expect(ReleaseFeed.offer(from: json, localCommit: "111111") == nil)
}
