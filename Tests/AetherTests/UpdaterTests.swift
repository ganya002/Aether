import AppKit
import CryptoKit
import Foundation
import Testing
@testable import AetherKit

private func release(
    tag: String = "build-abc123",
    build: Int? = 2000,
    assets: [String] = ["Aether.app.zip", "Aether.app.zip.sha256", "Aether.app.zip.sig"]
) -> Data {
    let notes = build.map { "Update abc123\\n\\naether-build: \($0)" } ?? "Update abc123"
    let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }
    return #"{"tag_name":"\#(tag)","body":"\#(notes)","assets":[\#(list.joined(separator: ","))]}"#.data(using: .utf8)!
}

private let installed = BuildStamp(commit: "111111", build: 1000)

@Test func newerBuildOfferPointsAtTheAssets() throws {
    let offer = try #require(ReleaseFeed.offer(from: release(), local: installed))
    #expect(offer.commit == "abc123")
    #expect(offer.build == 2000)
    #expect(offer.zip.absoluteString == "https://example.com/Aether.app.zip")
    #expect(offer.checksum.absoluteString == "https://example.com/Aether.app.zip.sha256")
    #expect(offer.signature?.absoluteString == "https://example.com/Aether.app.zip.sig")
}

@Test func sameCommitIsNotAnUpdate() {
    #expect(ReleaseFeed.offer(from: release(), local: BuildStamp(commit: "ABC123", build: 0)) == nil)
}

@Test func olderOrEqualBuildIsNeverOffered() {
    #expect(ReleaseFeed.offer(from: release(build: 1000), local: installed) == nil)
    #expect(ReleaseFeed.offer(from: release(build: 999), local: installed) == nil)
    #expect(ReleaseFeed.offer(from: release(build: 1001), local: installed) != nil)
}

@Test func releaseWithoutABuildNumberIsNotOffered() {
    #expect(ReleaseFeed.offer(from: release(build: nil), local: BuildStamp(commit: "111111", build: 0)) == nil)
}

@Test func devBuildDoesNotNagForEveryRelease() {
    #expect(ReleaseFeed.offer(from: release(), local: BuildStamp(commit: "dev", build: 0)) == nil)
    #expect(ReleaseFeed.offer(from: release(), local: BuildStamp(commit: "", build: 0)) == nil)
}

@Test func releaseWithoutTheZipOrChecksumIsIgnored() {
    #expect(ReleaseFeed.offer(from: release(assets: ["notes.txt"]), local: installed) == nil)
    #expect(ReleaseFeed.offer(from: release(assets: ["Aether.app.zip"]), local: installed) == nil)
    let unsigned = ReleaseFeed.offer(from: release(assets: ["Aether.app.zip", "Aether.app.zip.sha256"]), local: installed)
    #expect(unsigned != nil)
    #expect(unsigned?.signature == nil)
}

@Test func buildNumberIsReadFromTheNotes() {
    #expect(ReleaseFeed.build(inNotes: "Update x\n\naether-build: 1761500000") == 1761500000)
    #expect(ReleaseFeed.build(inNotes: "AETHER-BUILD:42\r\n") == 42)
    #expect(ReleaseFeed.build(inNotes: "aether-build: soon") == nil)
    #expect(ReleaseFeed.build(inNotes: "") == nil)
}

@Test func buildStampReadsTheInfoPlist() {
    let stamp = BuildStamp(info: ["AetherCommit": "abcdef1234", "AetherBuild": "1761500000", "CFBundleShortVersionString": "2.0.0"])
    #expect(stamp.build == 1761500000)
    #expect(stamp.isRelease)
    #expect(stamp.shortCommit == "abcdef1")
    #expect(BuildStamp(info: ["AetherCommit": "dev"]).shortCommit == "dev")
    #expect(BuildStamp(info: [:]).build == 0)
}

private func temporaryZip(_ bytes: String = "pretend this is Aether.app.zip") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AetherTest-\(UUID().uuidString).zip")
    try Data(bytes.utf8).write(to: url)
    return url
}

private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

@Test func checksumMustMatchTheZip() throws {
    let zip = try temporaryZip()
    defer { try? FileManager.default.removeItem(at: zip) }
    let good = try digest(zip)
    #expect(try UpdateVerifier.sha256(of: zip) == good)
    try UpdateVerifier.verifyArchive(zip, checksumText: "\(good)  Aether.app.zip\n", signature: nil, publicKey: nil)
    #expect(throws: UpdateVerifier.Failure.checksumMismatch) {
        try UpdateVerifier.verifyArchive(zip, checksumText: String(repeating: "0", count: 64), signature: nil, publicKey: nil)
    }
    #expect(throws: UpdateVerifier.Failure.missingChecksum) {
        try UpdateVerifier.verifyArchive(zip, checksumText: "<html>Not Found</html>", signature: nil, publicKey: nil)
    }
}

@Test func signatureIsRequiredOnceAKeyIsEmbedded() throws {
    let zip = try temporaryZip()
    defer { try? FileManager.default.removeItem(at: zip) }
    let checksum = try digest(zip)
    let key = Curve25519.Signing.PrivateKey()
    let info: [String: Any] = [UpdateVerifier.publicKeyInfoKey: key.publicKey.rawRepresentation.base64EncodedString()]
    let embedded = try #require(try UpdateVerifier.publicKey(from: info))

    let signed = try key.signature(for: Data(contentsOf: zip))
    let asset = Data(signed.base64EncodedString().appending("\n").utf8)
    let parsed = try #require(UpdateVerifier.signature(in: asset))
    try UpdateVerifier.verifyArchive(zip, checksumText: checksum, signature: parsed, publicKey: embedded)

    #expect(throws: UpdateVerifier.Failure.missingSignature) {
        try UpdateVerifier.verifyArchive(zip, checksumText: checksum, signature: nil, publicKey: embedded)
    }
    let stranger = try Curve25519.Signing.PrivateKey().signature(for: Data(contentsOf: zip))
    #expect(throws: UpdateVerifier.Failure.badSignature) {
        try UpdateVerifier.verifyArchive(zip, checksumText: checksum, signature: stranger, publicKey: embedded)
    }
}

@Test func noEmbeddedKeyMeansChecksumOnly() throws {
    #expect(try UpdateVerifier.publicKey(from: [:]) == nil)
    #expect(try UpdateVerifier.publicKey(from: [UpdateVerifier.publicKeyInfoKey: "  "]) == nil)
    #expect(throws: UpdateVerifier.Failure.badPublicKey) {
        try UpdateVerifier.publicKey(from: [UpdateVerifier.publicKeyInfoKey: "not a key"])
    }
}

@Test func stagedAppMustBeTheOfferedAether() throws {
    let offer = try #require(ReleaseFeed.offer(from: release(), local: installed))
    let good: [String: Any] = ["CFBundleIdentifier": "com.ganya.Aether", "AetherCommit": "abc1234567", "AetherBuild": "2000"]
    try UpdateVerifier.verifyStaged(info: good, bundleIdentifier: "com.ganya.Aether", offer: offer)

    var other = good
    other["CFBundleIdentifier"] = "com.example.Evil"
    #expect(throws: UpdateVerifier.Failure.wrongApp) {
        try UpdateVerifier.verifyStaged(info: other, bundleIdentifier: "com.ganya.Aether", offer: offer)
    }
    var stale = good
    stale["AetherCommit"] = "fedcba9876"
    #expect(throws: UpdateVerifier.Failure.wrongCommit) {
        try UpdateVerifier.verifyStaged(info: stale, bundleIdentifier: "com.ganya.Aether", offer: offer)
    }
    var replayed = good
    replayed["AetherBuild"] = "1500"
    #expect(throws: UpdateVerifier.Failure.wrongBuild) {
        try UpdateVerifier.verifyStaged(info: replayed, bundleIdentifier: "com.ganya.Aether", offer: offer)
    }
}

private func makeBundle(_ app: URL, marker: String) throws {
    let macOS = app.appendingPathComponent("Contents/MacOS")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Aether").path)
    try Data(marker.utf8).write(to: resources.appendingPathComponent("marker"))
    let plist: [String: Any] = ["CFBundleExecutable": "Aether", "CFBundleIdentifier": "com.ganya.Aether.test"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
}

/// Runs the real swap script against throwaway bundles, without detaching or relaunching.
private func runSwap(staged: URL, installed: URL) throws -> Int32 {
    let script = try UpdateInstaller.writeSwapScript(next: staged)
    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try gone.run()
    gone.waitUntilExit()
    let swap = Process()
    swap.executableURL = URL(fileURLWithPath: "/bin/bash")
    swap.arguments = [script.path, String(gone.processIdentifier), staged.path, installed.path, "0"]
    swap.environment = ["AETHER_UPDATE_DETACHED": "1", "PATH": "/usr/bin:/bin"]
    swap.standardOutput = FileHandle.nullDevice
    swap.standardError = FileHandle.nullDevice
    try swap.run()
    swap.waitUntilExit()
    return swap.terminationStatus
}

private func marker(in app: URL) throws -> String {
    try String(contentsOf: app.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8)
}

@Test func swapReplacesTheBundleAndCleansUp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherSwap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let installedApp = root.appendingPathComponent("Install/Aether.app")
    let staging = root.appendingPathComponent("Staging")
    let stagedApp = staging.appendingPathComponent("Aether.app")
    try makeBundle(installedApp, marker: "old")
    try makeBundle(stagedApp, marker: "new")

    #expect(try runSwap(staged: stagedApp, installed: installedApp) == 0)
    #expect(try marker(in: installedApp) == "new")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: installedApp.deletingLastPathComponent().path)
    #expect(leftovers == ["Aether.app"])
}

@Test func failedSwapKeepsTheInstalledApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherSwap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let installedApp = root.appendingPathComponent("Install/Aether.app")
    let stagedApp = root.appendingPathComponent("Staging/Aether.app")
    try makeBundle(installedApp, marker: "old")
    try makeBundle(stagedApp, marker: "new")
    // A loose file in Contents makes codesign refuse the bundle.
    try Data("x".utf8).write(to: stagedApp.appendingPathComponent("Contents/stray"))

    #expect(try runSwap(staged: stagedApp, installed: installedApp) == 1)
    #expect(try marker(in: installedApp) == "old")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: installedApp.deletingLastPathComponent().path)
    #expect(leftovers == ["Aether.app"])
}

@Test @MainActor func updateToastOnlyTakesClicksInTheCorner() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let toast = UpdateVeil(frame: host.bounds)
    host.addSubview(toast)
    toast.showReady()
    toast.layoutSubtreeIfNeeded()
    #expect(toast.hitTest(NSPoint(x: 450, y: 300)) == nil)
    #expect(toast.hitTest(NSPoint(x: 40, y: 30)) == nil)
    #expect(toast.hitTest(NSPoint(x: 870, y: 38)) != nil)
    #expect(toast.hitTest(NSPoint(x: 870, y: 120)) == nil)
}
