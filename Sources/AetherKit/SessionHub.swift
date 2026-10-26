import AppKit
import CryptoKit
import Foundation
import Network

enum CloudLink: Equatable {
    case idle
    case connecting
    case reconnecting
    case connected
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Local"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .connected: "Connected"
        case .unavailable(let message), .failed(let message): message
        }
    }
}

/// What happened to one Cloud terminal's connection, for the pane to show.
enum CloudSessionEvent {
    /// The link is down and Aether stopped retrying. The shell may still be running on the server.
    case disconnected
    /// The link is back and the terminal was attached again.
    case restored
    /// The server no longer has this terminal.
    case gone
}

/// One connection to the session server. Panes share it. The server keeps the shells alive after this app quits.
@MainActor
final class SessionHub {
    static let shared = SessionHub()
    static let connectTimeout: UInt64 = 10_000_000_000
    static let backoff: [Double] = [1, 2, 4, 8, 15, 30]

    var onLink: ((CloudLink) -> Void)?
    private(set) var link: CloudLink = .idle {
        didSet {
            onLink?(link)
            let note: String
            switch link {
            case .connected: note = "Cloud"
            case .idle: note = ""
            default: note = link.title
            }
            for pane in AppModel.shared.panes.values where pane.chrome.terminal.remoteSession != nil {
                pane.chrome.header.setCloud(note)
            }
        }
    }

    func setLink(_ next: CloudLink) {
        link = next
    }

    var isOpen: Bool { opened }

    private var connection: NWConnection?
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var useSocket = false
    private var frames = FrameDecoder()
    private var opened = false
    private var connecting = false
    private var generation = 0
    private var connectedHost = ""
    private var connectedWS = ""
    private var connectedToken = ""
    /// Terminals this app is showing, with their last size. These are attached again after a reconnect.
    private var sizes: [String: (Int, Int)] = [:]
    private var resync: [String: () -> Void] = [:]
    private var events: [String: (CloudSessionEvent) -> Void] = [:]
    private var earlyStatus: [String: (String, String)] = [:]
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var pending = PendingQueue<CheckedContinuation<String, Error>>()
    private var nextReq = 0
    private var output: [String: (Data) -> Void] = [:]
    private var earlyOutput: [String: Data] = [:]
    private var status: [String: (String, String) -> Void] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var askingAboutAccount = false
    private var approvals: Task<Void, Never>?
    private var agentsInFlight = 0
    /// Terminals closed while the link was down. They are closed on the server once it is back.
    private var closing: Set<String> = []

    private init() {}

    // MARK: Connecting

    func open() async throws {
        do {
            try await connectTransport()
        } catch SessionError.unauthorized {
            throw SessionError.unauthorized
        } catch {
            guard await retarget() else { throw error }
            try await connectTransport()
        }
    }

    /// The public address can move. Keep this person's token and follow the published URL.
    private func retarget() async -> Bool {
        guard let endpoint = await CloudCatalog.published(), !endpoint.ws.isEmpty else { return false }
        guard endpoint.ws != AppModel.shared.settings.sessionWS else { return false }
        AppModel.shared.updateSettings { settings in
            settings.sessionHost = endpoint.sessionHost
            settings.sessionWS = endpoint.ws
        }
        teardown()
        return true
    }

    private func connectTransport() async throws {
        let settings = AppModel.shared.settings
        let host = settings.sessionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let ws = settings.sessionWS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SessionError.unconfigured }
        if !ws.isEmpty {
            guard let url = CloudCatalog.socketURL(from: ws) else {
                throw SessionError.server("Cloud's address isn't secure.")
            }
            try await openSocket(url, token: token)
            return
        }
        guard !host.isEmpty else { throw SessionError.unconfigured }
        if opened, connection != nil, connectedHost == host, connectedToken == token {
            link = .connected
            return
        }
        if connecting {
            try await waitUntilOpen()
            return
        }
        let gen = begin(token: token)
        useSocket = false
        connectedHost = host
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: 7391))
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.note(state, token: token)
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receive(conn)
        try await waitUntilOpen(gen)
    }

    private func openSocket(_ url: URL, token: String) async throws {
        if opened, socket != nil, connectedWS == url.absoluteString, connectedToken == token {
            link = .connected
            return
        }
        if connecting {
            try await waitUntilOpen()
            return
        }
        let gen = begin(token: token)
        useSocket = true
        connectedWS = url.absoluteString
        let session = URLSession(configuration: .ephemeral)
        socketSession = session
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receiveSocket(task)
        send(["type": "hello", "token": token, "client": "mac"])
        try await waitUntilOpen(gen)
    }

    /// Drops any old transport and marks a fresh attempt. Returns its generation so late callbacks can be ignored.
    private func begin(token: String) -> Int {
        teardown()
        connecting = true
        connectedToken = token
        if reconnectTask == nil {
            link = .connecting
        }
        return generation
    }

    /// Drops the transport. Requests still waiting on it fail, since their answers can't arrive anymore.
    private func teardown() {
        pending.drain().forEach { $0.resume(throwing: SessionError.disconnected) }
        pending.echoesReq = false
        generation += 1
        opened = false
        connecting = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = nil
        useSocket = false
        connectedHost = ""
        connectedWS = ""
        frames.reset()
    }

    /// Waits for helloOk. With a generation, also gives up after the connect timeout.
    private func waitUntilOpen(_ gen: Int? = nil) async throws {
        var timeout: Task<Void, Never>?
        if let gen {
            timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.connectTimeout)
                guard !Task.isCancelled, self.generation == gen, self.connecting else { return }
                self.fail(SessionError.timedOut)
            }
        }
        defer { timeout?.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            waiters.append(cont)
        }
    }

    private func note(_ state: NWConnection.State, token: String) {
        switch state {
        case .ready:
            send(["type": "hello", "token": token, "client": "mac"])
        case .waiting(let error), .failed(let error):
            fail(error)
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        let waiting = waiters
        waiters = []
        let queued = pending.drain()
        let hadTransport = connecting || opened || connection != nil || socket != nil
        guard hadTransport || !waiting.isEmpty || !queued.isEmpty else { return }
        teardown()
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        link = .failed(text)
        waiting.forEach { $0.resume(throwing: error) }
        queued.forEach { $0.resume(throwing: error) }
        if case SessionError.unauthorized = error {
            for id in sizes.keys { events[id]?(.disconnected) }
            askAboutAccount()
            return
        }
        scheduleReconnect()
    }

    // MARK: Reconnecting

    /// Retries with growing pauses while panes still show Cloud terminals. Gives up after a few minutes and
    /// tells each pane, which offers a Reconnect button.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !sizes.isEmpty else { return }
        reconnectTask = Task { @MainActor in
            for delay in Self.backoff {
                self.link = .reconnecting
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                if self.opened { break }
                do {
                    try await self.open()
                    break
                } catch SessionError.unauthorized {
                    break
                } catch {
                    continue
                }
            }
            self.reconnectTask = nil
            if self.opened {
                await self.reattachAll()
            } else {
                if case .reconnecting = self.link {
                    self.link = .failed("Disconnected")
                }
                for id in self.sizes.keys { self.events[id]?(.disconnected) }
            }
        }
    }

    /// Skips the wait and tries again now, for the pane's Reconnect button and for typing into a dead pane.
    func reconnectNow() {
        guard !opened, !connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        guard !sizes.isEmpty else { return }
        reconnectTask = Task { @MainActor in
            self.link = .reconnecting
            do {
                try await self.open()
            } catch {
                self.reconnectTask = nil
                for id in self.sizes.keys { self.events[id]?(.disconnected) }
                return
            }
            self.reconnectTask = nil
            await self.reattachAll()
        }
    }

    private func reattachAll() async {
        for (id, size) in sizes {
            resync[id]?()
            do {
                try await attach(id: id, cols: size.0, rows: size.1)
                events[id]?(.restored)
            } catch SessionError.server(let message) where message == "no such session" {
                sizes[id] = nil
                events[id]?(.gone)
            } catch {
                events[id]?(.disconnected)
            }
        }
    }

    // MARK: Sessions

    func create(cwd: String, cols: Int, rows: Int, command: String?) async throws -> String {
        try await open()
        return try await request(["type": "create", "cwd": cwd, "cols": cols, "rows": rows, "command": command ?? ""]) { msg in
            msg["type"] as? String == "created" ? msg["id"] as? String : nil
        }
    }

    func attach(id: String, cols: Int, rows: Int) async throws {
        try await open()
        _ = try await request(["type": "attach", "id": id, "cols": cols, "rows": rows]) { msg in
            (msg["type"] as? String == "attached" && msg["id"] as? String == id) ? id : nil
        }
    }

    /// A pane is showing this terminal. Tracked terminals are attached again after a reconnect.
    func track(_ id: String, cols: Int, rows: Int) {
        sizes[id] = (max(cols, 1), max(rows, 1))
        closing.remove(id)
    }

    func input(_ id: String, data: Data) {
        guard opened else {
            reconnectNow()
            return
        }
        send(["type": "input", "id": id, "data": data.base64EncodedString()])
    }

    func resize(_ id: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let size = sizes[id] {
            guard size != (cols, rows) else { return }
            sizes[id] = (cols, rows)
        }
        guard opened else { return }
        send(["type": "resize", "id": id, "cols": cols, "rows": rows])
    }

    func close(_ id: String) {
        if opened {
            send(["type": "close", "id": id])
        } else {
            closing.insert(id)
        }
        forget(id)
    }

    /// Stops showing a terminal without ending it. It stays on the server and in the Cloud list.
    func detach(_ id: String) {
        forget(id)
        closing.remove(id)
    }

    private func forget(_ id: String) {
        output[id] = nil
        status[id] = nil
        resync[id] = nil
        events[id] = nil
        sizes[id] = nil
        earlyOutput[id] = nil
        earlyStatus[id] = nil
    }

    func onResync(_ id: String, _ body: @escaping () -> Void) {
        resync[id] = body
    }

    func onEvent(_ id: String, _ body: @escaping (CloudSessionEvent) -> Void) {
        events[id] = body
    }

    func onOutput(_ id: String, _ body: @escaping (Data) -> Void) {
        output[id] = body
        if let pending = earlyOutput.removeValue(forKey: id), !pending.isEmpty {
            body(pending)
        }
    }

    func onStatus(_ id: String, _ body: @escaping (String, String) -> Void) {
        status[id] = body
        if let pending = earlyStatus.removeValue(forKey: id) {
            body(pending.0, pending.1)
        }
    }

    private func request(_ msg: [String: Any], match: @escaping ([String: Any]) -> String?) async throws -> String {
        guard opened else { throw SessionError.disconnected }
        nextReq += 1
        let req = "r\(nextReq)"
        var tagged = msg
        tagged["req"] = req
        return try await withCheckedThrowingContinuation { cont in
            pending.add(req: req, match: match, waiter: cont)
            send(tagged)
        }
    }

    // MARK: Account

    /// Makes a new Cloud account. The token it replaces is kept in the keychain.
    func enroll() async throws {
        guard let endpoint = await CloudCatalog.published() else {
            throw SessionError.server("Cloud isn't publicly available yet.")
        }
        let creds = try await CloudCatalog.enroll(at: endpoint)
        TokenVault.shared.backup(AppModel.shared.settings.sessionToken)
        teardown()
        for id in sizes.keys { events[id]?(.gone) }
        sizes.removeAll()
        AppModel.shared.updateSettings { settings in
            settings.sessionHost = creds.host
            settings.sessionToken = creds.token
            settings.sessionWS = creds.ws
            settings.cloudEnabled = true
        }
    }

    /// Forgets this Mac's Cloud account. The token is kept in the keychain as the previous one.
    func signOut() {
        reconnectTask?.cancel()
        reconnectTask = nil
        TokenVault.shared.backup(AppModel.shared.settings.sessionToken)
        let waiting = waiters
        waiters = []
        let queued = pending.drain()
        teardown()
        waiting.forEach { $0.resume(throwing: SessionError.unconfigured) }
        queued.forEach { $0.resume(throwing: SessionError.unconfigured) }
        for id in sizes.keys { events[id]?(.disconnected) }
        AppModel.shared.updateSettings { settings in
            settings.sessionHost = ""
            settings.sessionToken = ""
            settings.sessionWS = ""
            settings.cloudEnabled = false
        }
        link = .idle
    }

    /// The server refused this token. Never replace it without asking: a new account loses the old sessions.
    private func askAboutAccount() {
        guard !askingAboutAccount else { return }
        askingAboutAccount = true
        link = .failed("Cloud rejected this sign-in.")
        Task { @MainActor in
            defer { self.askingAboutAccount = false }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Your Cloud sign-in was rejected."
            alert.informativeText = "Start a new Cloud account? Your old sessions won't come back."
            alert.addButton(withTitle: "Keep Trying")
            alert.addButton(withTitle: "Start New Account")
            guard await CloudPrompt.ask(alert) == .alertSecondButtonReturn else { return }
            do {
                self.link = .connecting
                try await self.enroll()
                try await self.open()
            } catch {
                self.link = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Agent requests

    private func handleAgent(_ msg: [String: Any]) {
        let requestID = msg["id"] as? String ?? ""
        let path = msg["path"] as? String ?? ""
        var body = msg["body"] as? [String: Any] ?? [:]
        // A Cloud request names its own Cloud terminal by session. It never gets to pick a local pane by id.
        body.removeValue(forKey: "pane")
        let deadline = CloudPrompt.deadline(msg["deadline"])
        let previous = approvals
        // Only a wait for a person is checked against the deadline. Requests that run right
        // away are never refused over a few seconds of clock difference with the server.
        let queued = agentsInFlight > 0
        agentsInFlight += 1
        approvals = Task { @MainActor in
            await previous?.value
            defer { self.agentsInFlight -= 1 }
            var result = await self.runAgent(path: path, body: body, deadline: deadline, queued: queued)
            result["type"] = "agentResult"
            result["id"] = requestID
            self.send(result)
        }
    }

    private func runAgent(path: String, body: [String: Any], deadline: Date?, queued: Bool) async -> [String: Any] {
        if case .failure(let error) = AppModel.shared.cloudTarget(body) {
            return ["ok": false, "error": error.message]
        }
        if queued, CloudPrompt.expired(deadline, now: Date()) {
            return ["ok": false, "error": "The Mac took too long to answer."]
        }
        let answer = await approve(path: path, body: body)
        guard answer.allowed else { return ["ok": false, "error": "Declined on the Mac."] }
        if queued || answer.asked, CloudPrompt.expired(deadline, now: Date()) {
            // Nobody is waiting for the answer anymore, so a late yes runs nothing.
            return ["ok": false, "error": "Allowed too late."]
        }
        return AppModel.shared.agent(path: path, body: body, fromCloud: true)
    }

    /// Anything that runs a command needs a yes from the person at this Mac, and so does listing
    /// every pane. Everything else acts only on the Cloud terminal that asked, so it goes ahead.
    private func approve(path: String, body: [String: Any]) async -> (allowed: Bool, asked: Bool) {
        let command = CloudPrompt.command(in: body)
        guard command != nil || CloudPrompt.needsApproval(path) else { return (true, false) }
        let account = CloudPrompt.fingerprint(AppModel.shared.settings.sessionToken)
        if CloudPrompt.trusted(account) { return (true, false) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let command {
            let place = AppModel.shared.settings.usesCloud ? "in a new Cloud terminal" : "on this Mac"
            alert.messageText = "Your Cloud device wants to run a command \(place)."
            alert.informativeText = command
        } else {
            alert.messageText = "Your Cloud device wants to read what's on screen in Aether."
            alert.informativeText = "It will see the titles of your terminals."
        }
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always allow from this account"
        let allowed = await CloudPrompt.ask(alert) == .alertSecondButtonReturn
        if allowed, alert.suppressionButton?.state == .on {
            CloudPrompt.trust(account)
        }
        return (allowed, true)
    }

    // MARK: Wire

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    let bodies: [Data]
                    do {
                        bodies = try self.frames.append(data)
                    } catch {
                        self.fail(SessionError.server("The Cloud service sent something Aether couldn't read."))
                        return
                    }
                    for body in bodies {
                        guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
                        self.deliver(msg)
                        guard self.connection === conn else { return }
                    }
                }
                if let error {
                    self.fail(error)
                    return
                }
                if complete {
                    self.fail(SessionError.disconnected)
                    return
                }
                self.receive(conn)
            }
        }
    }

    private func receiveSocket(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let raw): data = raw
                    @unknown default: data = nil
                    }
                    if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.deliver(msg)
                    }
                    if self.socket === task {
                        self.receiveSocket(task)
                    }
                case .failure(let error):
                    self.fail(error)
                }
            }
        }
    }

    private func deliver(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        if type == "helloOk" {
            guard connecting else { return }
            opened = true
            connecting = false
            pending.echoesReq = msg["echoesReq"] as? Bool ?? false
            link = .connected
            for id in closing {
                send(["type": "close", "id": id])
            }
            closing.removeAll()
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
            return
        }
        if type == "error" {
            let message = msg["message"] as? String ?? "The Cloud service refused."
            if connecting {
                fail(message == "unauthorized" ? SessionError.unauthorized : SessionError.server(message))
                return
            }
            pending.takeError(msg)?.resume(throwing: SessionError.server(message))
            return
        }
        guard opened else { return }
        if type == "output", let id = msg["id"] as? String, let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64) {
            if let handler = output[id] {
                handler(data)
            } else if (earlyOutput[id]?.count ?? 0) < 4 << 20 {
                earlyOutput[id, default: Data()].append(data)
            }
            return
        }
        if type == "status", let id = msg["id"] as? String {
            let state = msg["state"] as? String ?? ""
            let text = msg["msg"] as? String ?? ""
            if let handler = status[id] {
                handler(state, text)
            } else {
                earlyStatus[id] = (state, text)
            }
            return
        }
        if type == "resync", let id = msg["id"] as? String {
            resync[id]?()
            if let size = sizes[id] {
                send(["type": "attach", "id": id, "cols": size.0, "rows": size.1])
            }
            return
        }
        if type == "closed", let id = msg["id"] as? String {
            sizes[id] = nil
            status[id]?("done", "exited")
            return
        }
        if let (cont, value) = pending.takeMatch(msg) {
            cont.resume(returning: value)
            return
        }
        if type == "agent" {
            handleAgent(msg)
        }
    }

    private func send(_ msg: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        if useSocket {
            guard let socket, let text = String(data: body, encoding: .utf8) else { return }
            socket.send(.string(text)) { _ in }
            return
        }
        guard let connection else { return }
        connection.send(content: FrameDecoder.frame(body), completion: .contentProcessed { _ in })
    }
}

/// Requests waiting for the server's answer. Pure, so the matching rules can be tested.
struct PendingQueue<Waiter> {
    struct Entry {
        var req: String
        var match: ([String: Any]) -> String?
        var waiter: Waiter
    }

    private(set) var entries: [Entry] = []
    /// The server tags each direct answer with the request's "req". Older servers don't.
    var echoesReq = false

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(req: String, match: @escaping ([String: Any]) -> String?, waiter: Waiter) {
        entries.append(Entry(req: req, match: match, waiter: waiter))
    }

    mutating func drain() -> [Waiter] {
        defer { entries.removeAll() }
        return entries.map(\.waiter)
    }

    /// The request an error answers. A tagged error answers its own request. An untagged one
    /// answers nothing on a server that tags, since it came from a message nobody waits on.
    /// Older servers answer in order, so there it is the oldest request.
    mutating func takeError(_ msg: [String: Any]) -> Waiter? {
        if let req = msg["req"] as? String {
            guard let index = entries.firstIndex(where: { $0.req == req }) else { return nil }
            return entries.remove(at: index).waiter
        }
        guard !echoesReq, !entries.isEmpty else { return nil }
        return entries.removeFirst().waiter
    }

    mutating func takeMatch(_ msg: [String: Any]) -> (Waiter, String)? {
        guard let index = entries.firstIndex(where: { $0.match(msg) != nil }) else { return nil }
        let entry = entries.remove(at: index)
        return (entry.waiter, entry.match(msg) ?? "")
    }
}

enum SessionError: Error, LocalizedError, Equatable {
    case unconfigured
    case unauthorized
    case timedOut
    case disconnected
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unconfigured: "Cloud is not configured."
        case .unauthorized: "Cloud rejected this sign-in."
        case .timedOut: "The Cloud service did not answer."
        case .disconnected: "Disconnected from Cloud."
        case .server(let message): message
        }
    }
}

@MainActor
enum CloudPrompt {
    private static let trustKey = "cloudTrustedAccounts"

    /// Shows the alert on the front Aether window, or on its own when there is none.
    static func ask(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        let model = AppModel.shared
        let window = model.keyDeskID.flatMap { model.controllers[$0]?.window }
        guard let window, window.isVisible else {
            NSApp.requestUserAttention(.criticalRequest)
            return alert.runModal()
        }
        if !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
        }
        return await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
        }
    }

    /// Requests that show more than the asking terminal, so the person at the Mac decides.
    nonisolated static func needsApproval(_ path: String) -> Bool {
        path == "/view"
    }

    /// The server's deadline for a request, in Unix milliseconds. Nil when it sent none.
    nonisolated static func deadline(_ raw: Any?) -> Date? {
        let ms: Double
        if let value = raw as? Double { ms = value }
        else if let value = raw as? Int { ms = Double(value) }
        else if let value = raw as? NSNumber { ms = value.doubleValue }
        else { return nil }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    nonisolated static func expired(_ deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now > deadline
    }

    nonisolated static func command(in body: [String: Any]) -> String? {
        guard let raw = body["command"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func trusted(_ account: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: trustKey) ?? []).contains(account)
    }

    static func trust(_ account: String) {
        var list = UserDefaults.standard.stringArray(forKey: trustKey) ?? []
        guard !list.contains(account) else { return }
        list.append(account)
        UserDefaults.standard.set(list, forKey: trustKey)
    }
}
