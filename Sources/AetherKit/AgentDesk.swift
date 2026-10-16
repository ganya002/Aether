import AppKit
import Foundation
import Network

/// Local control socket so an agent on this Mac can open panes, place them, and read the screen.
@MainActor
final class AgentDesk {
    static let shared = AgentDesk()
    private var listener: NWListener?
    private let token: String

    private init() {
        let url = System.supportDirectory().appendingPathComponent("agent.plist")
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let existing = plist["token"] as? String {
            token = existing
        } else {
            token = UUID().uuidString
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: 17393)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                Task { @MainActor in
                    AgentDesk.shared.serve(connection)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            writeCredentials()
            installHelper()
        } catch {
            return
        }
    }

    private func writeCredentials() {
        let url = System.supportDirectory().appendingPathComponent("agent.plist")
        let body: [String: Any] = ["port": 17393, "token": token]
        if let data = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func installHelper() {
        let dir = System.supportDirectory().appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("aether")
        try? AgentCLI.source.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let skillDir = System.supportDirectory().appendingPathComponent("skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try? AgentCLI.skill.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, _ in
            let raw = data ?? Data()
            Task { @MainActor in
                let response = AgentDesk.shared.answer(raw)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func answer(_ raw: Data) -> Data {
        let text = String(decoding: raw, as: UTF8.self)
        let header = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        guard header.contains(token) || text.contains(token) else {
            return http(401, ["error": "unauthorized"])
        }
        guard let bodyStart = text.range(of: "\r\n\r\n") else {
            return http(400, ["error": "bad request"])
        }
        let body = String(text[bodyStart.upperBound...])
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let result = AppModel.shared.agent(path: path, body: json)
        return http(200, result)
    }

    private func http(_ code: Int, _ json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

enum AgentCLI {
    static let source = """
    #!/bin/sh
    PLIST="$HOME/Library/Application Support/Aether/agent.plist"
    if [ -n "$AETHER_SESSION" ]; then
      PORT=0
      TOKEN=""
    elif [ ! -f "$PLIST" ]; then
      echo "Aether is not running." >&2
      exit 1
    else
      PORT=$(plutil -extract port raw "$PLIST")
      TOKEN=$(plutil -extract token raw "$PLIST")
    fi
    cmd="$1"
    shift
    python3 - "$cmd" "$PORT" "$TOKEN" "$@" << 'PY'
    import json, sys, urllib.request
    cmd, port, token, *args = sys.argv[1:]
    def flag(name, default=None):
        if name in args:
            i = args.index(name)
            if i + 1 < len(args):
                return args[i + 1]
        return default
    body = {}
    path = "/split"
    if cmd == "tab":
        path = "/tab"
    elif cmd == "font":
        path = "/font"
        body["delta"] = float(flag("--delta", args[0] if args else "1"))
    elif cmd == "zoom":
        path = "/zoom"
    elif cmd == "read":
        path = "/read"
    elif cmd == "view":
        path = "/view"
    elif cmd == "open":
        path = "/open"
        body["kind"] = args[0] if args else "web"
        body["target"] = args[1] if len(args) > 1 else ""
    elif cmd == "skill":
        import os, shutil
        home = os.path.expanduser("~")
        candidates = [os.path.expanduser("~/Library/Application Support/Aether/skill/SKILL.md"), "/usr/local/share/aether/SKILL.md"]
        src = next((path for path in candidates if os.path.exists(path)), "")
        homes = [os.path.join(home, ".claude", "skills", "aether"), os.path.join(home, ".agents", "skills", "aether"), os.path.join(home, ".cursor", "skills", "aether")]
        for dest in homes:
            os.makedirs(dest, exist_ok=True)
            if os.path.exists(src):
                shutil.copy(src, os.path.join(dest, "SKILL.md"))
                print(dest)
        sys.exit(0)
    elif cmd != "split":
        print("commands: split, tab, open, font, zoom, read, view, skill", file=sys.stderr)
        sys.exit(2)
    body["direction"] = flag("--split", "right")
    body["ratio"] = float(flag("--ratio", "50"))
    if "--" in args:
        body["command"] = " ".join(args[args.index("--") + 1:])
    import os
    session = os.environ.get("AETHER_SESSION", "")
    if session:
        payload = {"path": path, "body": body, "session": session}
        token = os.environ.get("AETHER_TOKEN", "")
        req = urllib.request.Request("http://127.0.0.1:7392/agent", data=json.dumps(payload).encode(), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    else:
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(), headers={"Authorization": token, "Content-Type": "application/json"})
    print(urllib.request.urlopen(req, timeout=8).read().decode())
    PY
    """

    static let skill = """
    ---
    name: aether
    description: Control the Aether terminal the agent is running in. Open tabs, split panes, place a page or PDF, change type size, and read the screen.
    ---

    You are in Aether when `AETHER_PANE` is set. Run `aether` to change the layout. Do not guess keystrokes for splits.

    - `aether split --split right --ratio 30 -- command` places a terminal on the right, left, top, or bottom. Ratio is the new pane's share, from 10 to 80.
    - `aether tab -- command` opens another terminal.
    - `aether open web https://example.com --split right --ratio 40` shows a page in a pane.
    - `aether open pdf /path/file.pdf --split bottom` shows a PDF in a pane.
    - `aether font --delta 1` or `--delta -1` changes the type size. `--delta 0` resets it.
    - `aether zoom` fills the window with the focused pane.
    - `aether read` prints the focused terminal's screen.
    - `aether view` prints the panes.

    "Beside you" means split the pane in `AETHER_PANE`. Leave focus alone unless asked. Close only panes you opened.
    """
}
