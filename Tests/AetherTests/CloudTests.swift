import Foundation
import Testing
@testable import AetherKit

private func json(_ text: String) -> Data {
    FrameDecoder.frame(Data(text.utf8))
}

@Test func framesSurviveTheSecondMessage() throws {
    var decoder = FrameDecoder()
    let first = try decoder.append(json(#"{"type":"helloOk"}"#))
    #expect(first.map { String(decoding: $0, as: UTF8.self) } == [#"{"type":"helloOk"}"#])
    let second = try decoder.append(json(#"{"type":"created","id":"a"}"#) + json(#"{"type":"output"}"#))
    #expect(second.map { String(decoding: $0, as: UTF8.self) } == [#"{"type":"created","id":"a"}"#, #"{"type":"output"}"#])
    #expect(decoder.buffer.isEmpty)
}

@Test func framesArriveAByteAtATime() throws {
    var decoder = FrameDecoder()
    let stream = json(#"{"a":1}"#) + json(#"{"b":2}"#) + json(#"{"c":3}"#)
    var bodies: [String] = []
    for byte in stream {
        bodies += try decoder.append(Data([byte])).map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(bodies == [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
    #expect(decoder.buffer.isEmpty)
}

@Test func partialFrameWaitsForTheRest() throws {
    var decoder = FrameDecoder()
    let frame = json(#"{"type":"status"}"#)
    #expect(try decoder.append(frame.prefix(6)).isEmpty)
    #expect(try decoder.append(frame.dropFirst(6)).count == 1)
}

@Test func badFrameLengthDropsTheConnection() {
    var zero = FrameDecoder()
    #expect(throws: FrameDecoder.Failure.invalidLength(0)) {
        try zero.append(Data([0, 0, 0, 0, 1, 2]))
    }
    #expect(zero.buffer.isEmpty)

    var huge = FrameDecoder()
    let size = FrameDecoder.maxLength + 1
    let head = Data([UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
    #expect(throws: FrameDecoder.Failure.invalidLength(size)) {
        try huge.append(head)
    }
    #expect(huge.buffer.isEmpty)
}

@Test func frameHeaderIsBigEndian() {
    let frame = FrameDecoder.frame(Data(repeating: 0x41, count: 0x0102))
    #expect(Array(frame.prefix(4)) == [0, 0, 1, 2])
    #expect(frame.count == 4 + 0x0102)
}

@Test func cloudOnlyEnrollsOverHTTPS() {
    #expect(CloudCatalog.enrollURL(from: "https://cloud.example.com/enroll") != nil)
    #expect(CloudCatalog.enrollURL(from: "http://cloud.example.com/enroll") == nil)
    #expect(CloudCatalog.enrollURL(from: "ftp://cloud.example.com/enroll") == nil)
    #expect(CloudCatalog.enrollURL(from: "") == nil)
    #expect(CloudCatalog.enrollURL(from: "https:///enroll") == nil)
}

@Test func publishedEndpointUsesSecureSocket() throws {
    let endpoint = try #require(CloudCatalog.endpoint(for: URL(string: "https://cloud.example.com:8443/enroll")!))
    #expect(endpoint.ws == "wss://cloud.example.com:8443/ws")
    #expect(endpoint.sessionHost == "cloud.example.com")
    #expect(CloudCatalog.endpoint(for: URL(string: "http://cloud.example.com/enroll")!) == nil)
}

@Test func plainSocketsOnlyReachThisMac() {
    #expect(CloudCatalog.socketURL(from: "wss://cloud.example.com/ws") != nil)
    #expect(CloudCatalog.socketURL(from: "ws://cloud.example.com/ws") == nil)
    #expect(CloudCatalog.socketURL(from: "ws://localhost:7392/ws") != nil)
    #expect(CloudCatalog.socketURL(from: "ws://127.0.0.1:7392/ws") != nil)
    #expect(CloudCatalog.socketURL(from: "https://cloud.example.com/ws") == nil)
    #expect(CloudCatalog.socketURL(from: "") == nil)
}

private final class MemoryStore: SecretStore {
    var items: [String: String] = [:]
    var refuseWrites = false
    var failReads = false
    var deletes = 0

    func read(_ account: String) -> SecretRead {
        if failReads { return .failed }
        return items[account].map(SecretRead.found) ?? .missing
    }

    func write(_ value: String, account: String) -> Bool {
        guard !refuseWrites else { return false }
        items[account] = value
        return true
    }

    func delete(_ account: String) -> Bool {
        deletes += 1
        items[account] = nil
        return true
    }
}

@MainActor @Test func plaintextTokenMovesIntoTheKeychain() {
    let store = MemoryStore()
    let vault = TokenVault(store: store)
    #expect(vault.adopt(fileToken: "secret") == "secret")
    #expect(store.items[TokenVault.account] == "secret")
    #expect(vault.diskToken(for: "secret") == "")
    var settings = Settings(sessionHost: "h", sessionToken: "secret")
    settings = settings.forDisk(vault)
    #expect(settings.sessionToken == "")
}

@MainActor @Test func tokenComesBackFromTheKeychain() {
    let store = MemoryStore()
    store.items[TokenVault.account] = "kept"
    let vault = TokenVault(store: store)
    #expect(vault.adopt(fileToken: "") == "kept")
    #expect(vault.diskToken(for: "kept") == "")
}

@MainActor @Test func tokenStaysInTheFileWhenTheKeychainRefuses() {
    let store = MemoryStore()
    store.refuseWrites = true
    let vault = TokenVault(store: store)
    #expect(vault.adopt(fileToken: "secret") == "secret")
    #expect(vault.diskToken(for: "secret") == "secret")
}

@MainActor @Test func unreadableKeychainIsNeverWiped() {
    let store = MemoryStore()
    store.items[TokenVault.account] = "kept"
    store.failReads = true
    let vault = TokenVault(store: store)
    #expect(vault.adopt(fileToken: "") == "")
    #expect(vault.unreadable)
    #expect(vault.diskToken(for: "") == "")
    #expect(store.deletes == 0)
    #expect(store.items[TokenVault.account] == "kept")
}

@MainActor @Test func newTokenReplacesOldOneAndBackupKeepsIt() {
    let store = MemoryStore()
    let vault = TokenVault(store: store)
    _ = vault.adopt(fileToken: "old")
    vault.backup("old")
    #expect(vault.diskToken(for: "new") == "")
    #expect(store.items[TokenVault.account] == "new")
    #expect(vault.previousToken() == "old")
    #expect(vault.diskToken(for: "") == "")
    #expect(store.items[TokenVault.account] == nil)
}

@Test func olderConfigsKeepTheirCloudChoice() throws {
    let cloud = try JSONDecoder().decode(Settings.self, from: Data(#"{"sessionHost":"h","sessionToken":"t"}"#.utf8))
    #expect(cloud.cloudEnabled)
    #expect(cloud.usesCloud)
    let local = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(!local.cloudEnabled)
    var parked = cloud
    parked.cloudEnabled = false
    #expect(!parked.usesCloud)
    #expect(parked.hasCloudAccount)
}

@Test func onlyRequestsWithACommandNeedApproval() {
    #expect(CloudPrompt.command(in: ["command": "rm -rf ~"]) == "rm -rf ~")
    #expect(CloudPrompt.command(in: ["command": "   "]) == nil)
    #expect(CloudPrompt.command(in: ["direction": "right"]) == nil)
    #expect(CloudPrompt.fingerprint("a") != CloudPrompt.fingerprint("b"))
}
