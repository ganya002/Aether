import AppKit
import CryptoKit
import Darwin
import Foundation

/// What a copy of Aether says about itself in its Info.plist.
struct BuildStamp: Equatable {
    var commit: String
    /// Monotonic: the commit's Unix timestamp, stamped by build-app.sh. 0 when unknown.
    var build: Int
    var version: String

    init(commit: String, build: Int, version: String = "") {
        self.commit = commit
        self.build = build
        self.version = version
    }

    init(info: [String: Any]) {
        commit = (info["AetherCommit"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        build = Self.number(info["AetherBuild"]) ?? 0
        version = info["CFBundleShortVersionString"] as? String ?? ""
    }

    static var current: BuildStamp {
        BuildStamp(info: Bundle.main.infoDictionary ?? [:])
    }

    /// Copies built outside git are stamped "dev". They never update themselves.
    var isRelease: Bool { ReleaseFeed.isCommit(commit) }

    var shortCommit: String { isRelease ? String(commit.prefix(7)) : "dev" }

    static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

enum ReleaseFeed {
    static let latest = URL(string: "https://api.github.com/repos/ganya002/Aether/releases/latest")!
    static let assetName = "Aether.app.zip"
    static let checksumName = "Aether.app.zip.sha256"
    static let signatureName = "Aether.app.zip.sig"

    struct Offer: Equatable {
        var commit: String
        var build: Int
        var zip: URL
        var checksum: URL
        var signature: URL?
    }

    /// A release is offered only when its build number is strictly newer than this app's.
    /// The tag stays `build-<commit>` so older copies of Aether keep finding releases.
    /// The build number lives in the release notes as `aether-build: <number>`.
    static func offer(from data: Data, local: BuildStamp) -> Offer? {
        guard local.isRelease else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let commit = tag.hasPrefix("build-") ? String(tag.dropFirst("build-".count)) : tag
        guard isCommit(commit) else { return nil }
        if sameCommit(local.commit, commit) { return nil }
        guard let build = build(inNotes: json["body"] as? String ?? ""), build > local.build else { return nil }
        guard let zip = url(of: assetName, in: assets),
              let checksum = url(of: checksumName, in: assets) else { return nil }
        return Offer(commit: commit, build: build, zip: zip, checksum: checksum, signature: url(of: signatureName, in: assets))
    }

    static func build(inNotes notes: String) -> Int? {
        for line in notes.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "aether-build" else { continue }
            if let value = Int(parts[1].trimmingCharacters(in: .whitespaces)), value > 0 { return value }
        }
        return nil
    }

    private static func url(of name: String, in assets: [[String: Any]]) -> URL? {
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              let string = asset["browser_download_url"] as? String,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }

    static func isCommit(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...40).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy(\.isHexDigit)
    }

    static func sameCommit(_ local: String, _ remote: String) -> Bool {
        let left = local.lowercased()
        let right = remote.lowercased()
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.hasPrefix(right) || right.hasPrefix(left)
    }
}

/// Every downloaded update is checked before it can be installed:
/// the zip must match the published SHA-256, carry a valid Ed25519 signature
/// when this app embeds a public key, and unpack to the same app at the offered commit.
enum UpdateVerifier {
    static let publicKeyInfoKey = "AetherUpdatePublicKey"

    enum Failure: Error, Equatable {
        case missingChecksum
        case checksumMismatch
        case missingSignature
        case badSignature
        case badPublicKey
        case wrongApp
        case wrongCommit
        case wrongBuild
    }

    /// nil when no key is embedded. A key that is present but unreadable is an error,
    /// so a typo can't quietly turn signatures off.
    static func publicKey(from info: [String: Any]) throws -> Curve25519.Signing.PublicKey? {
        let text = (info[publicKeyInfoKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let raw = Data(base64Encoded: text),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw Failure.badPublicKey
        }
        return key
    }

    /// Accepts a bare digest or `shasum -a 256` output ("<digest>  Aether.app.zip").
    static func checksum(in text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).first else { return nil }
        let digest = first.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
        return digest
    }

    /// The .sig asset is the base64 of a 64-byte Ed25519 signature over the zip's bytes.
    static func signature(in data: Data) -> Data? {
        if let text = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           decoded.count == 64 {
            return decoded
        }
        return data.count == 64 ? data : nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyArchive(
        _ zip: URL,
        checksumText: String,
        signature: Data?,
        publicKey: Curve25519.Signing.PublicKey?
    ) throws {
        guard let expected = checksum(in: checksumText) else { throw Failure.missingChecksum }
        guard try sha256(of: zip) == expected else { throw Failure.checksumMismatch }
        guard let publicKey else { return }
        guard let signature else { throw Failure.missingSignature }
        let bytes = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard publicKey.isValidSignature(signature, for: bytes) else { throw Failure.badSignature }
    }

    static func verifyStaged(info: [String: Any], bundleIdentifier: String?, offer: ReleaseFeed.Offer) throws {
        guard let bundleIdentifier, info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw Failure.wrongApp
        }
        let stamp = BuildStamp(info: info)
        guard stamp.isRelease, ReleaseFeed.sameCommit(stamp.commit, offer.commit) else { throw Failure.wrongCommit }
        guard stamp.build == offer.build else { throw Failure.wrongBuild }
    }
}

@MainActor
final class UpdateCenter {
    static let shared = UpdateCenter()

    static let upToDate = "You're up to date"
    static let devBuild = "Development build — updates are off"

    var onStatus: ((String) -> Void)?
    /// How many terminals are running a command right now. Restart to Update asks first when this isn't 0.
    var busyTerminalCount: () -> Int = { UpdateCenter.countBusyTerminals() }

    private var busy = false
    private var quitting = false
    private var lastCheck = Date.distantPast
    private var timer: Timer?
    private var watchingUpdates = false
    private var transfer: Transfer?
    private var staged: (offer: ReleaseFeed.Offer, app: URL)?
    private var downloading: ReleaseFeed.Offer?
    /// The commit whose toast the user put off with Later. Cleared on relaunch, ignored for newer releases.
    private var dismissedCommit: String?
    private var terminateObserver: NSObjectProtocol?
    private var phase: Phase = .idle
    private var warnedUnsigned = false

    private enum Phase {
        case idle
        case checking
        case downloading
        case ready
    }

    private init() {}

    func start() {
        applyPreference()
    }

    /// Background checks run only when Settings asks for them. A manual check still works either way.
    func applyPreference() {
        let enabled = AppModel.shared.settings.checkForUpdates && Bundle.main.bundleURL.pathExtension == "app"
        if enabled == watchingUpdates { return }
        watchingUpdates = enabled
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in
                await UpdateCenter.shared.check()
            }
        }
        Task { await check() }
    }

    func checkSoon() {
        guard AppModel.shared.settings.checkForUpdates else { return }
        guard Date().timeIntervalSince(lastCheck) > 120 else { return }
        Task { await check() }
    }

    /// Settings uses this so a click always looks, even if a background check just ran.
    func checkNow() async -> String {
        await check(manual: true)
    }

    /// Background checks stop as soon as the setting is off. A check the user just asked for still runs.
    private func mayLook(_ manual: Bool) -> Bool {
        manual || AppModel.shared.settings.checkForUpdates
    }

    private func isDismissed(_ offer: ReleaseFeed.Offer) -> Bool {
        dismissedCommit.map { ReleaseFeed.sameCommit($0, offer.commit) } ?? false
    }

    @discardableResult
    func check(manual: Bool = false) async -> String {
        guard mayLook(manual) else { return "" }
        let local = BuildStamp.current
        if System.isDev || !local.isRelease {
            if manual { report(Self.devBuild) }
            return Self.devBuild
        }
        if phase == .downloading {
            if manual, let downloading {
                dismissedCommit = nil
                presentDownloading(downloading)
            }
            return "Downloading update…"
        }
        guard !busy, !quitting else { return "Checking…" }
        guard !CommandLine.arguments.contains("--smoke") else { return "" }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return Self.upToDate }
        busy = true
        let wasReady = phase == .ready
        phase = .checking
        if manual { report("Checking…") }
        lastCheck = Date()
        defer {
            transfer = nil
            busy = false
            if phase == .checking { phase = wasReady ? .ready : .idle }
        }
        do {
            var request = URLRequest(url: ReleaseFeed.latest)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Aether", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let message = "Couldn't check for updates"
                if manual { report(message) }
                return message
            }
            // An update that is already staged counts as this app's version, so only a newer one replaces it.
            var floor = local
            if let staged { floor.build = max(floor.build, staged.offer.build); floor.commit = staged.offer.commit }
            guard mayLook(manual) else { return "" }
            guard let offer = ReleaseFeed.offer(from: data, local: floor) else {
                if let staged {
                    phase = .ready
                    if manual { dismissedCommit = nil }
                    if !quitting, manual || (!isDismissed(staged.offer) && !gaugeIsShowing()) {
                        presentReady()
                    }
                    report("Update ready")
                    return "Update ready"
                }
                report(Self.upToDate)
                return Self.upToDate
            }
            if manual { dismissedCommit = nil }
            report("Update found")
            try await download(offer, manual: manual)
            return phase == .ready ? "Update ready" : ""
        } catch {
            downloading = nil
            if staged != nil {
                phase = .ready
            } else {
                hideGauge()
                phase = .idle
            }
            let message = Self.describe(error)
            report(message)
            return message
        }
    }

    private static func describe(_ error: Error) -> String {
        if error is UpdateVerifier.Failure {
            NSLog("Aether update rejected: \(error)")
            return "The update didn't pass its safety check"
        }
        return "Couldn't check for updates"
    }

    private func download(_ offer: ReleaseFeed.Offer, manual: Bool) async throws {
        phase = .downloading
        downloading = offer
        presentDownloading(offer)
        let zip = try await fetch(offer.zip) { [weak self] fraction in
            guard let self, self.downloading == offer else { return }
            self.visibleToast()?.gauge.fraction = fraction
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        let checksumText = String(decoding: try await fetchSmall(offer.checksum), as: UTF8.self)
        let publicKey = try UpdateVerifier.publicKey(from: Bundle.main.infoDictionary ?? [:])
        var signature: Data?
        if publicKey != nil, let url = offer.signature {
            signature = UpdateVerifier.signature(in: try await fetchSmall(url))
        } else if publicKey == nil, !warnedUnsigned {
            warnedUnsigned = true
            NSLog("Aether update signatures are off: no AetherUpdatePublicKey in Info.plist. Checking SHA-256 only.")
        }
        let identifier = Bundle.main.bundleIdentifier
        let app = try await Task.detached {
            try UpdateVerifier.verifyArchive(zip, checksumText: checksumText, signature: signature, publicKey: publicKey)
            let app = try UpdateInstaller.unarchive(zip)
            do {
                let plist = app.appendingPathComponent("Contents/Info.plist")
                let info = NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
                try UpdateVerifier.verifyStaged(info: info, bundleIdentifier: identifier, offer: offer)
            } catch {
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                throw error
            }
            return app
        }.value
        downloading = nil
        if let old = staged {
            try? FileManager.default.removeItem(at: old.app.deletingLastPathComponent())
        }
        staged = (offer, app)
        phase = .ready
        guard mayLook(manual) else {
            hideGauge()
            return
        }
        // A manual check clears Later before it starts, so this only holds back a toast the user put off mid-download.
        if !isDismissed(offer) {
            presentReady()
        } else {
            hideGauge()
        }
    }

    func installNow() {
        guard phase != .downloading, let staged, !quitting else { return }
        let running = busyTerminalCount()
        if running > 0, !confirmRestart(running: running) { return }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            report("Aether can't replace itself in this folder")
            visibleToast()?.showMessage("Move Aether to Applications to update")
            return
        }
        let log = System.supportDirectory().appendingPathComponent("update.log")
        let script: URL
        do {
            script = try UpdateInstaller.writeSwapScript(next: staged.app)
        } catch {
            report("Couldn't install the update")
            return
        }
        // The swap starts only once AppKit has committed to quitting. A quit the user cancels
        // leaves this copy running, with the update still ready.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            try? UpdateInstaller.launchSwap(script: script, staged: staged.app, destination: destination, log: log, relaunch: true)
        }
        quitting = true
        visibleToast()?.setRestarting(true)
        // The restart was already confirmed above, so the quit check must not ask again or defer the quit.
        AppModel.shared.quitConfirmed = true
        NSApp.terminate(nil)
        AppModel.shared.quitConfirmed = false
        // terminate(_:) returns only when the quit was cancelled.
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        terminateObserver = nil
        quitting = false
        visibleToast()?.setRestarting(false)
    }

    func dismissForNow() {
        dismissedCommit = staged?.offer.commit ?? downloading?.commit
        hideGauge()
    }

    private func confirmRestart(running: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restart Aether to update?"
        alert.informativeText = running == 1
            ? "A terminal is running a command. Restarting stops it, and every terminal starts a new shell."
            : "\(running) terminals are running commands. Restarting stops them, and every terminal starts a new shell."
        alert.addButton(withTitle: "Restart to Update")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A local terminal is busy when something other than its shell owns the foreground,
    /// or when the pane was opened to run a command rather than a shell.
    static func countBusyTerminals() -> Int {
        AppModel.shared.panes.values.filter { pane in
            guard let process = pane.chrome.terminal.process, process.running, process.childfd >= 0 else { return false }
            if let command = pane.command, !command.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            let group = tcgetpgrp(process.childfd)
            return group > 0 && group != process.shellPid
        }.count
    }

    @discardableResult
    private func presentDownloading(_ offer: ReleaseFeed.Offer) -> UpdateVeil? {
        guard !isDismissed(offer), let toast = presentToast() else { return visibleToast() }
        toast.showDownloading()
        return toast
    }

    private func presentToast() -> UpdateVeil? {
        guard let host = hostController() else { return nil }
        let toast = host.showUpdateGauge()
        toast.onInstall = { UpdateCenter.shared.installNow() }
        toast.onLater = { UpdateCenter.shared.dismissForNow() }
        return toast
    }

    private func presentReady() {
        guard let toast = presentToast() else { return }
        toast.showReady()
    }

    private func visibleToast() -> UpdateVeil? {
        for controller in AppModel.shared.controllers.values {
            guard let root = controller.window?.contentView else { continue }
            if let toast = Self.findUpdateVeil(root) { return toast }
        }
        return nil
    }

    private func gaugeIsShowing() -> Bool {
        visibleToast() != nil
    }

    private static func findUpdateVeil(_ view: NSView) -> UpdateVeil? {
        if let veil = view as? UpdateVeil { return veil }
        if let glass = view as? NSGlassEffectView, let content = glass.contentView, content !== view,
           let found = findUpdateVeil(content) {
            return found
        }
        for subview in view.subviews {
            if let found = findUpdateVeil(subview) { return found }
        }
        return nil
    }

    private func report(_ message: String) {
        onStatus?(message)
    }

    private func fetch(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let transfer = Transfer(progress: progress, continuation: continuation)
            self.transfer = transfer
            transfer.start(url)
        }
    }

    /// Checksums and signatures are a few bytes. Anything large is not one of them.
    private func fetchSmall(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Aether", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count < 4096 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func hostController() -> DeskController? {
        if let id = AppModel.shared.keyDeskID, let controller = AppModel.shared.controllers[id] {
            return controller
        }
        return AppModel.shared.controllers.values.first { $0.window?.isVisible == true }
    }

    private func hideGauge() {
        for controller in AppModel.shared.controllers.values {
            controller.hideUpdateGauge()
        }
    }
}

private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var saved: URL?
    private var failure: Error?

    init(progress: @escaping @MainActor (Double) -> Void, continuation: CheckedContinuation<URL, Error>) {
        self.progress = progress
        self.continuation = continuation
    }

    func start(_ url: URL) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Aether", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        Task { @MainActor in
            self.progress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200...299).contains(code) else {
            failure = URLError(.badServerResponse)
            return
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Aether-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            saved = destination
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = continuation
        self.continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if let error {
            if let saved { try? FileManager.default.removeItem(at: saved) }
            continuation?.resume(throwing: error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else if let saved {
            continuation?.resume(returning: saved)
        } else {
            continuation?.resume(throwing: URLError(.unknown))
        }
    }
}

enum UpdateInstaller {
    static func unarchive(_ zip: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("AetherUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        do {
            try ditto.run()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        ditto.waitUntilExit()
        let app = staging.appendingPathComponent("Aether.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            try? FileManager.default.removeItem(at: staging)
            throw CocoaError(.fileReadCorruptFile)
        }
        return app
    }

    /// Waits for Aether to quit, then swaps the bundles. The old copy is moved aside first
    /// and put back if the new one can't be moved in, so a failure never leaves no app at all.
    /// Arguments: pid, staged app, installed app, relaunch (1 or 0).
    static let swapScript = """
    #!/bin/bash
    if [[ "${AETHER_UPDATE_DETACHED:-}" != "1" ]]; then
      AETHER_UPDATE_DETACHED=1 nohup /bin/bash "$0" "$@" >>"${AETHER_UPDATE_LOG:-/dev/null}" 2>&1 </dev/null &
      exit 0
    fi
    pid="$1"
    src="$2"
    dest="$3"
    relaunch="${4:-1}"
    say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.2
    done
    parent="$(dirname "$dest")"
    name="$(basename "$dest")"
    tmp="$parent/.$name.updating.$$"
    backup="$parent/.$name.previous.$$"
    reopen() {
      if [[ "$relaunch" == "1" ]]; then open "$dest" || true; fi
    }
    fail() {
      say "update failed: $1"
      rm -rf "$tmp"
      reopen
      exit 1
    }
    say "installing $src over $dest"
    rm -rf "$tmp"
    /usr/bin/ditto "$src" "$tmp" || fail "couldn't copy the new app"
    /usr/bin/xattr -dr com.apple.quarantine "$tmp" 2>/dev/null || true
    /usr/bin/codesign --force --sign - "$tmp" || fail "couldn't sign the new app"
    if [[ -e "$dest" ]]; then
      mv "$dest" "$backup" || fail "couldn't move the old app aside"
    fi
    if ! mv "$tmp" "$dest"; then
      say "update failed: couldn't move the new app in, restoring the old one"
      if [[ -e "$backup" ]]; then mv "$backup" "$dest" || say "the old app is at $backup"; fi
      rm -rf "$tmp"
      reopen
      exit 1
    fi
    rm -rf "$backup" || say "left $backup behind"
    say "installed"
    reopen
    rm -rf "$(dirname "$src")"
    """

    static func writeSwapScript(next staged: URL) throws -> URL {
        let script = staged.deletingLastPathComponent().appendingPathComponent("relaunch.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    /// Hands the swap to a detached shell. The shell waits until this process is gone.
    static func launchSwap(script: URL, staged: URL, destination: URL, log: URL, relaunch: Bool) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            destination.path,
            relaunch ? "1" : "0",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["AETHER_UPDATE_LOG"] = log.path
        environment.removeValue(forKey: "AETHER_UPDATE_DETACHED")
        helper.environment = environment
        try helper.run()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
