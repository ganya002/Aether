import AppKit
import Foundation

enum ReleaseFeed {
    static let latest = URL(string: "https://api.github.com/repos/ganya002/Aether/releases/latest")!
    static let assetName = "Aether.app.zip"

    struct Offer: Equatable {
        var commit: String
        var zip: URL
    }

    /// A release is newer when its `build-<commit>` tag differs from the commit baked into this app.
    static func offer(from data: Data, localCommit: String) -> Offer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let commit = tag.hasPrefix("build-") ? String(tag.dropFirst("build-".count)) : tag
        guard isCommit(commit) else { return nil }
        // A copy built outside git is stamped "dev". Offering every release would nag forever.
        guard isCommit(localCommit) else { return nil }
        if sameCommit(localCommit, commit) { return nil }
        guard let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let urlString = asset["browser_download_url"] as? String,
              let zip = URL(string: urlString) else { return nil }
        return Offer(commit: commit, zip: zip)
    }

    private static func isCommit(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...40).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy(\.isHexDigit)
    }

    private static func sameCommit(_ local: String, _ remote: String) -> Bool {
        let left = local.lowercased()
        let right = remote.lowercased()
        return left == right || left.hasPrefix(right) || right.hasPrefix(left)
    }
}

@MainActor
final class UpdateCenter {
    static let shared = UpdateCenter()

    var onStatus: ((String) -> Void)?
    private var busy = false
    private var quitting = false
    private var lastCheck = Date.distantPast
    private var timer: Timer?
    private var watchingUpdates = false
    private var transfer: Transfer?
    private var stagedApp: URL?
    private var phase: Phase = .idle

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

    func installNow() {
        guard phase == .ready, let stagedApp, !quitting else { return }
        do {
            try UpdateInstaller.relaunchReplacingBundle(with: stagedApp)
            quitting = true
        } catch {
            report("Couldn't install the update")
        }
    }

    /// Background checks stop as soon as the setting is off. A check the user just asked for still runs.
    private func mayLook(_ manual: Bool) -> Bool {
        manual || AppModel.shared.settings.checkForUpdates
    }

    @discardableResult
    func check(manual: Bool = false) async -> String {
        guard mayLook(manual) else { return "" }
        if phase == .ready {
            // Activate and the timer call check() again while an update is already staged.
            // presentReady() inserts the gauge at the front of the key window, so a click
            // that wakes the app covers the pane that was just focused. Show it only when
            // the user asked, or when no window still has the gauge.
            if !quitting, manual || !gaugeIsShowing() {
                presentReady()
            }
            return "Update found"
        }
        if phase == .downloading {
            return "Update found"
        }
        guard !busy, !quitting else { return "Checking…" }
        guard !CommandLine.arguments.contains("--smoke") else { return "" }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "You're up to date" }
        busy = true
        phase = .checking
        if manual { report("Checking…") }
        lastCheck = Date()
        defer {
            transfer = nil
            if !quitting, phase != .downloading, phase != .ready {
                busy = false
                if phase == .checking { phase = .idle }
            }
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
            let local = Bundle.main.object(forInfoDictionaryKey: "AetherCommit") as? String ?? ""
            guard let offer = ReleaseFeed.offer(from: data, localCommit: local) else {
                report("You're up to date")
                return "You're up to date"
            }
            guard mayLook(manual) else { return "" }
            report("Update found")
            try await download(offer, manual: manual)
            return phase == .ready ? "Update found" : ""
        } catch {
            hideGauge()
            phase = .idle
            busy = false
            let message = "Couldn't check for updates"
            report(message)
            return message
        }
    }

    private func download(_ offer: ReleaseFeed.Offer, manual: Bool) async throws {
        guard mayLook(manual) else {
            phase = .idle
            busy = false
            return
        }
        guard let veil = presentGauge() else {
            phase = .idle
            busy = false
            return
        }
        phase = .downloading
        busy = true
        veil.setInstallEnabled(false)
        veil.gauge.fraction = 0
        let zip = try await fetch(offer.zip) { fraction in
            veil.gauge.fraction = fraction
        }
        guard mayLook(manual) else {
            hideGauge()
            phase = .idle
            busy = false
            return
        }
        veil.gauge.fraction = 1
        let staged = try await Task.detached {
            try UpdateInstaller.unarchive(zip)
        }.value
        guard mayLook(manual) else {
            hideGauge()
            phase = .idle
            busy = false
            return
        }
        stagedApp = staged
        phase = .ready
        busy = false
        presentReady()
    }

    private func presentGauge() -> UpdateVeil? {
        guard let host = hostController() else { return nil }
        let veil = host.showUpdateGauge()
        veil.onInstall = { UpdateCenter.shared.installNow() }
        return veil
    }

    private func presentReady() {
        guard let veil = presentGauge() else { return }
        veil.gauge.fraction = 1
        veil.setInstallEnabled(true)
    }

    private func gaugeIsShowing() -> Bool {
        for controller in AppModel.shared.controllers.values {
            guard let root = controller.window?.contentView else { continue }
            if Self.containsUpdateVeil(root) { return true }
        }
        return false
    }

    private static func containsUpdateVeil(_ view: NSView) -> Bool {
        if view is UpdateVeil { return true }
        if let glass = view as? NSGlassEffectView, let content = glass.contentView, content !== view,
           containsUpdateVeil(content) {
            return true
        }
        for subview in view.subviews where containsUpdateVeil(subview) {
            return true
        }
        return false
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
        try ditto.run()
        ditto.waitUntilExit()
        let app = staging.appendingPathComponent("Aether.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return app
    }

    /// Hands the swap to a detached shell, then quits. The shell waits until this process is gone.
    static func relaunchReplacingBundle(with staged: URL) throws {
        let destination = Bundle.main.bundleURL
        let script = staged.deletingLastPathComponent().appendingPathComponent("relaunch.sh")
        let source = """
        #!/bin/bash
        if [[ "${AETHER_UPDATE_DETACHED:-}" != "1" ]]; then
          AETHER_UPDATE_DETACHED=1 nohup /bin/bash "$0" "$@" >>/tmp/aether-update.log 2>&1 &
          exit 0
        fi
        pid="$1"
        src="$2"
        dest="$3"
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2
        done
        parent="$(dirname "$dest")"
        tmp="$parent/Aether.app.updating"
        rm -rf "$tmp"
        if ! /usr/bin/ditto "$src" "$tmp"; then
          open "$dest" || true
          exit 1
        fi
        xattr -dr com.apple.quarantine "$tmp" || true
        /usr/bin/codesign --force --sign - "$tmp/Contents/MacOS/Aether" || true
        /usr/bin/codesign --force --sign - "$tmp" || true
        rm -rf "$dest"
        if ! mv "$tmp" "$dest"; then
          open "$tmp" || true
          exit 1
        fi
        open "$dest"
        rm -rf "$(dirname "$src")"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, destination.path]
        try helper.run()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSApp.terminate(nil)
    }
}
