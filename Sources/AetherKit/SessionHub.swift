import Foundation
import Network

enum CloudLink: Equatable {
    case idle
    case connecting
    case connected
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Local"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .unavailable(let message), .failed(let message): message
        }
    }
}

/// One connection to the session server. Panes share it. The server keeps the shells alive after this app quits.
@MainActor
final class SessionHub {
    static let shared = SessionHub()
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

    private var connection: NWConnection?
    private var buffer = Data()
    private var opened = false
    private var failed: Error?
    private var connecting = false
    private var connectedHost = ""
    private var connectedToken = ""
    private var earlyStatus: [String: (String, String)] = [:]
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var output: [String: (Data) -> Void] = [:]
    private var earlyOutput: [String: Data] = [:]
    private var status: [String: (String, String) -> Void] = [:]
    private let writeLock = NSLock()

    private init() {}

    func open() async throws {
        let settings = AppModel.shared.settings
        let host = settings.sessionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else { throw SessionError.unconfigured }
        if opened, connection != nil, connectedHost == host, connectedToken == token {
            link = .connected
            return
        }
        if connecting {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiters.append(cont)
            }
            return
        }
        connection?.cancel()
        connection = nil
        opened = false
        failed = nil
        connecting = true
        connectedHost = host
        connectedToken = token
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: 7391))
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.note(state, token: token)
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receive(conn)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            waiters.append(cont)
        }
    }

    func create(cwd: String, cols: Int, rows: Int, command: String?) async throws -> String {
        try await open()
        return try await request(["type": "create", "cwd": cwd, "cols": cols, "rows": rows, "command": command ?? ""]) { msg in
            msg["type"] as? String == "created" ? msg["id"] as? String : nil
        }
    }

    func attach(id: String, cols: Int, rows: Int) async throws {
        try await open()
        _ = try await request(["type": "attach", "id": id, "cols": cols, "rows": rows]) { msg in
            (msg["type"] as? String == "attached") ? id : nil
        }
    }

    func input(_ id: String, data: Data) {
        send(["type": "input", "id": id, "data": data.base64EncodedString()])
    }

    func resize(_ id: String, cols: Int, rows: Int) {
        send(["type": "resize", "id": id, "cols": cols, "rows": rows])
    }

    func close(_ id: String) {
        send(["type": "close", "id": id])
        output[id] = nil
        status[id] = nil
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

    private var pending: [( ([String: Any]) -> String? , CheckedContinuation<String, Error> )] = []

    private func request(_ msg: [String: Any], match: @escaping ([String: Any]) -> String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            pending.append((match, cont))
            send(msg)
        }
    }

    private func note(_ state: NWConnection.State, token: String) {
        switch state {
        case .ready:
            send(["type": "hello", "token": token])
        case .failed(let error):
            fail(error)
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        failed = nil
        connecting = false
        opened = false
        connection = nil
        link = .failed(error.localizedDescription)
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume(throwing: error) }
        let pending = self.pending
        self.pending = []
        pending.forEach { $0.1.resume(throwing: error) }
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drain()
                }
                if error != nil {
                    self.fail(error!)
                    return
                }
                if self.connection === conn {
                    self.receive(conn)
                }
            }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length > 0, length < 2 << 20, buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeFirst(4 + length)
            guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            deliver(msg)
        }
    }

    private func deliver(_ msg: [String: Any]) {
        if msg["type"] as? String == "helloOk" {
            opened = true
            connecting = false
            failed = nil
            link = .connected
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
            return
        }
        if msg["type"] as? String == "output", let id = msg["id"] as? String, let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64) {
            if let handler = output[id] {
                handler(data)
            } else {
                earlyOutput[id, default: Data()].append(data)
            }
            return
        }
        if msg["type"] as? String == "status", let id = msg["id"] as? String {
            let state = msg["state"] as? String ?? ""
            let text = msg["msg"] as? String ?? ""
            if let handler = status[id] {
                handler(state, text)
            } else {
                earlyStatus[id] = (state, text)
            }
            return
        }
        if let index = pending.firstIndex(where: { $0.0(msg) != nil }) {
            let value = pending[index].0(msg) ?? ""
            let cont = pending[index].1
            pending.remove(at: index)
            cont.resume(returning: value)
            return
        }
        if msg["type"] as? String == "agent" {
            let requestID = msg["id"] as? String ?? ""
            let path = msg["path"] as? String ?? ""
            let body = msg["body"] as? [String: Any] ?? [:]
            var result = AppModel.shared.agent(path: path, body: body)
            result["type"] = "agentResult"
            result["id"] = requestID
            send(result)
            return
        }
        if msg["type"] as? String == "error", let message = msg["message"] as? String {
            let pending = self.pending
            self.pending = []
            pending.forEach { $0.1.resume(throwing: SessionError.server(message)) }
        }
    }

    private func send(_ msg: [String: Any]) {
        guard let connection, let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var frame = Data(capacity: 4 + body.count)
        var n = UInt32(body.count).bigEndian
        frame.append(Data(bytes: &n, count: 4))
        frame.append(body)
        writeLock.lock()
        connection.send(content: frame, completion: .contentProcessed { _ in })
        writeLock.unlock()
    }
}

enum SessionError: Error {
    case unconfigured
    case server(String)
}
