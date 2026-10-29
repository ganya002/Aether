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

@Test @MainActor func updateCardOnlyTakesClicksInTheTopRightCorner() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let card = UpdateCard(frame: host.bounds)
    host.addSubview(card)
    card.show(.ready(UpdateDemo.offer))
    card.layoutSubtreeIfNeeded()
    #expect(card.hitTest(NSPoint(x: 450, y: 300)) == nil)
    #expect(card.hitTest(NSPoint(x: 40, y: 570)) == nil)
    #expect(card.hitTest(NSPoint(x: 870, y: 570)) != nil)
    #expect(card.hitTest(NSPoint(x: 870, y: 30)) == nil)
}

@Test func offerCarriesTheReleaseNotesVersionAndDate() throws {
    let json = #"""
    {"tag_name":"build-abc123","published_at":"2026-10-29T09:31:46Z",
     "body":"Faster tabs\n\naether-version: 2.1.0\naether-build: 2000",
     "assets":[{"name":"Aether.app.zip","browser_download_url":"https://example.com/z"},
               {"name":"Aether.app.zip.sha256","browser_download_url":"https://example.com/s"}]}
    """#
    let offer = try #require(ReleaseFeed.offer(from: Data(json.utf8), local: installed))
    #expect(offer.version == "2.1.0")
    #expect(offer.build == 2000)
    #expect(offer.published == Date(timeIntervalSince1970: 1_793_266_306))
    #expect(ReleaseNotes.lines(offer.notes) == ["Faster tabs"])
    // Releases from before version lines still work.
    #expect(try #require(ReleaseFeed.offer(from: release(), local: installed)).version == "")
}

@Test func releaseNotesDropMetadataAndRenderMarkdown() {
    let notes = "Update c557c1e777acae323aa9e5dbec4cb4d112e7c2e6\n\n## New\n- **Bold** and `code`\n\naether-build: 5"
    #expect(ReleaseNotes.lines(notes) == ["## New", "- **Bold** and `code`"])
    let text = ReleaseNotes.render(notes, ink: .white)
    #expect(text.string == "New\n•\tBold and code")
    let bold = text.attribute(.font, at: (text.string as NSString).range(of: "Bold").location, effectiveRange: nil) as? NSFont
    #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    let code = text.attribute(.font, at: (text.string as NSString).range(of: "code").location, effectiveRange: nil) as? NSFont
    #expect(code?.isFixedPitch == true)
}

@Test func downloadSpeedIsSmoothedAndGivesTimeLeft() {
    var progress = DownloadProgress()
    progress.advance(written: 0, total: 10_000_000, at: 0)
    #expect(progress.secondsLeft == nil)
    progress.advance(written: 1_000_000, total: 10_000_000, at: 0.5)
    #expect(progress.bytesPerSecond == 2_000_000)
    // Samples closer than a quarter second only move the byte count.
    progress.advance(written: 1_500_000, total: 10_000_000, at: 0.6)
    #expect(progress.bytesPerSecond == 2_000_000)
    #expect(progress.fraction == 0.15)
    #expect(progress.secondsLeft == 4.25)
    progress.advance(written: 1_500_000, total: 10_000_000, at: 1.0)
    #expect(progress.bytesPerSecond == 1_750_000)
    #expect(progress.detail.contains(" of "))
    #expect(progress.detail.hasSuffix("left"))
}

@Test func plainHttpAssetsAreOnlyForThisMachine() {
    let feed = { (host: String) -> Data in
        let assets = ["Aether.app.zip", "Aether.app.zip.sha256"].map { #"{"name":"\#($0)","browser_download_url":"http://\#(host)/\#($0)"}"# }
        return #"{"tag_name":"build-abc123","body":"aether-build: 2000","assets":[\#(assets.joined(separator: ","))]}"#.data(using: .utf8)!
    }
    #expect(ReleaseFeed.offer(from: feed("example.com"), local: installed) == nil)
    // Tests are debug builds, where a local feed may rehearse an install. Release builds refuse it too.
    #if DEBUG
    #expect(ReleaseFeed.offer(from: feed("127.0.0.1:8000"), local: installed) != nil)
    #else
    #expect(ReleaseFeed.offer(from: feed("127.0.0.1:8000"), local: installed) == nil)
    #endif
}

@Test @MainActor func passingStagesDissolveButErrorsAndChoicesWait() {
    #expect(UpdateStage.upToDate.linger == 2.5)
    #expect(UpdateStage.failed("x").linger == nil)
    #expect(UpdateStage.ready(UpdateDemo.offer).linger == nil)
    #expect(UpdateStage.upToDate.summary.hasPrefix("Up to date · checked "))
}
