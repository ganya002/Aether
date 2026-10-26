import AppKit
import Foundation
import Network

/// Local control socket so an agent on this Mac can open panes, place them, and read the screen.
@MainActor
final class AgentDesk {
    static let shared = AgentDesk()
    private var listener: NWListener?
    private let token: String
    static let port: UInt16 = System.isDev ? 17394 : 17393
    static let routes: Set<String> = ["/tab", "/split", "/open", "/font", "/zoom", "/read", "/view", "/status", "/notify", "/close"]
    /// Which pane asked for each pane, so an agent can close only what it opened.
    var openedBy: [String: String] = [:]

    private init() {
        let url = System.supportDirectory().appendingPathComponent("agent.plist")
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let existing = plist["token"] as? String, !existing.isEmpty {
            token = existing
        } else {
            token = UUID().uuidString
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: Self.parameters(port: Self.port))
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                Self.receive(connection, Data())
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    connection.cancel()
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

    /// Only this Mac may connect. The listener binds to 127.0.0.1, never to a network interface.
    nonisolated static func parameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.acceptLocalOnly = true
        return parameters
    }

    private func writeCredentials() {
        let url = System.supportDirectory().appendingPathComponent("agent.plist")
        let body: [String: Any] = ["port": Int(AgentDesk.port), "token": token]
        if let data = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func installHelper() {
        let dir = System.supportDirectory().appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("aether")
        try? (AgentCLI.source + "\n").write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let skillDir = System.supportDirectory().appendingPathComponent("skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try? (AgentCLI.skill + "\n").write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// Reads until the headers and the whole body have arrived, however TCP splits them.
    private nonisolated static func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            switch AgentHTTP.parse(next) {
            case .incomplete:
                if isComplete || error != nil {
                    reply(connection, AgentHTTP.response(400, ["ok": false, "error": "The request ended early."]))
                } else {
                    receive(connection, next)
                }
            case .invalid(let code, let message):
                reply(connection, AgentHTTP.response(code, ["ok": false, "error": message]))
            case .complete(let request):
                Task { @MainActor in
                    reply(connection, AgentDesk.shared.answer(request))
                }
            }
        }
    }

    private nonisolated static func reply(_ connection: NWConnection, _ response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func answer(_ request: AgentHTTP.Request) -> Data {
        guard AgentHTTP.authorized(request.headers["authorization"], token: token) else {
            return AgentHTTP.response(401, ["ok": false, "error": "unauthorized"])
        }
        guard request.method == "POST" || request.method == "GET" else {
            return AgentHTTP.response(405, ["ok": false, "error": "Use POST."])
        }
        guard Self.routes.contains(request.route) else {
            return AgentHTTP.response(404, ["ok": false, "error": "Unknown request \(request.route)."])
        }
        guard let body = AgentHTTP.json(request.body) else {
            return AgentHTTP.response(400, ["ok": false, "error": "The body is not a JSON object."])
        }
        return AgentHTTP.response(200, AppModel.shared.agent(path: request.route, body: body))
    }
}

/// The small slice of HTTP/1.1 the control socket speaks. Pure, so it can be tested without a socket.
enum AgentHTTP {
    static let limit = 1 << 20

    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        var route: String {
            String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
    }

    enum Parse: Equatable {
        case incomplete
        case complete(Request)
        case invalid(Int, String)
    }

    static func parse(_ data: Data, limit: Int = limit) -> Parse {
        let bytes = [UInt8](data)
        guard let end = headerEnd(bytes) else {
            return bytes.count > limit ? .invalid(413, "The request is too large.") : .incomplete
        }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), start[1].hasPrefix("/") else {
            return .invalid(400, "Bad request line.")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "Bad header.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(400, "Bad header.") }
            if let existing = headers[name], name == "content-length" || name == "authorization", existing != value {
                return .invalid(400, "Conflicting \(name) headers.")
            }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(411, "Send a Content-Length.")
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid(400, "Bad Content-Length.") }
            length = value
        }
        let bodyStart = end + 4
        guard bodyStart + length <= limit else { return .invalid(413, "The request is too large.") }
        guard bytes.count >= bodyStart + length else { return .incomplete }
        let body = Data(bytes[bodyStart..<(bodyStart + length)])
        return .complete(Request(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
    }

    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    /// The header must be the token itself, or `Bearer <token>`. Compared in constant time.
    static func authorized(_ header: String?, token: String) -> Bool {
        guard var given = header, !token.isEmpty else { return false }
        if given.hasPrefix("Bearer ") { given.removeFirst("Bearer ".count) }
        let a = Array(given.utf8)
        let b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }

    static func json(_ body: Data) -> [String: Any]? {
        if body.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func response(_ code: Int, _ json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(code) \(reason(code))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}

/// How agent requests map onto panes. Pure, so the rules can be tested without windows.
enum AgentArgs {
    /// The side a new pane goes on. Center would swap rather than split, so it means right.
    static func zone(_ raw: Any?) -> Zone? {
        guard let raw else { return .right }
        guard let text = raw as? String else { return nil }
        switch text.lowercased() {
        case "", "right", "center": return .right
        case "left": return .left
        case "top", "up": return .top
        case "bottom", "down": return .bottom
        default: return nil
        }
    }

    struct Target: Equatable {
        var desk: String
        var pane: String
        /// True when the request named its pane, rather than falling back to the focused one.
        var explicit: Bool
    }

    /// The pane a request is about: the one it names, else the one running its Cloud session,
    /// else the focused pane of the front window.
    static func target(pane: String?, session: String?, desks: [String: Desk], sessions: [String: String], keyDesk: String?) -> Result<Target, AgentError> {
        func desk(holding id: String) -> String? {
            desks.first { $0.value.panes[id] != nil }?.key
        }
        if let session, !session.isEmpty, let id = sessions.first(where: { $0.value == session })?.key, let deskID = desk(holding: id) {
            return .success(Target(desk: deskID, pane: id, explicit: true))
        }
        if let pane, !pane.isEmpty {
            guard let deskID = desk(holding: pane) else { return .failure(AgentError("No pane \(pane).")) }
            return .success(Target(desk: deskID, pane: pane, explicit: true))
        }
        guard let keyDesk, let focused = desks[keyDesk]?.focusedID else {
            return .failure(AgentError("No Aether window is open."))
        }
        return .success(Target(desk: keyDesk, pane: focused, explicit: false))
    }

    /// The last `count` lines of a buffer dump, without the blank rows below the prompt.
    static func tail(_ text: String, lines count: Int) -> String {
        var rows = text.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return rows.suffix(max(count, 0)).joined(separator: "\n")
    }
}

struct AgentError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Two copies of files in scripts/. AgentDeskTests fails if they drift; edit the file, then paste it here.
enum AgentCLI {
    static let source = #"""
    #!/bin/sh
    # aether: control the Aether terminal from a shell. Run `aether --help`.
    if ! command -v python3 >/dev/null 2>&1; then
      echo "aether: python3 is required. Install it with: xcode-select --install" >&2
      exit 1
    fi
    exec python3 - "$@" <<'PY'
    import base64, json, os, re, sys

    VERSION = "2"
    STATES = ("idle", "working", "blocked", "done", "error")
    DIRECTIONS = {"right": "right", "left": "left", "up": "top", "top": "top", "down": "bottom", "bottom": "bottom", "center": "right"}
    SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
    NUMBER = re.compile(r"^-?\d+(\.\d+)?$")


    CURRENT = ""


    class Usage(Exception):
        pass


    class Failure(Exception):
        pass


    PLACE = """
    Placement:
      --right, --left, --up, --down   Side of the pane to open on. Default: --right.
      --split <side>                  Same, as a value: right, left, up, down, top, bottom.
      --ratio <10-80>                 The new pane's share of the space, in percent.
      --focus                         Move the keyboard into the new pane. Default: leave focus alone."""

    COMMON = """
      --pane <id>                     Act on this pane instead of the one you are in ($AETHER_PANE).
      --json                          Print the raw reply."""

    HELP = {
        "": """usage: aether <command> [options]

    Control the Aether terminal you are running in. Commands act on your own pane
    ($AETHER_PANE) unless you pass --pane <id>.

    Commands:
      split     Open a terminal beside this pane.
      tab       Add a terminal to this window.
      open      Show a web page or PDF beside this pane.
      read      Print this pane's screen.
      view      List the panes.
      zoom      Make this pane fill its window, or put it back.
      font      Make the type bigger or smaller.
      status    Show what you are doing on this pane's header.
      notify    Post a macOS notification.
      title     Set this pane's title.
      close     Close a pane that you opened.
      skill     Install the Aether skill for Claude, Cursor, and other agents.
      help      Show help for a command.

    Options:
      -h, --help     Show help.
      --version      Show the version.

    Run `aether help <command>` for details and examples.""",
        "split": """usage: aether split [--right|--left|--up|--down] [--ratio N] [--focus] [-- command ...]

    Open a terminal beside this pane. Prints the new pane's id. Words after --
    run in the new pane; pass one quoted string for pipes and other shell syntax.
    """ + PLACE + COMMON + """

    Examples:
      aether split --right --ratio 30 -- npm run dev
      aether split --down -- tail -f log.txt
      aether split --left --focus
      aether split --up -- 'make 2>&1 | tee build.log'""",
        "tab": """usage: aether tab [--focus] [-- command ...]

    Add a terminal to this pane's window. Prints the new pane's id. Words after --
    run in the new pane.

    Options:
      --focus                         Move the keyboard into the new pane.""" + COMMON + """

    Examples:
      aether tab
      aether tab -- htop""",
        "open": """usage: aether open [web|pdf] <url-or-file> [--right|--left|--up|--down] [--ratio N]

    Show a web page or a PDF in a pane beside this one. Prints the new pane's id.
    Addresses without a scheme get http://, so `localhost:3000` works. Relative
    PDF paths are taken from the current directory.
    """ + PLACE + COMMON + """

    Examples:
      aether open localhost:3000 --right --ratio 40
      aether open web https://example.com
      aether open docs/spec.pdf --down""",
        "read": """usage: aether read [--lines N]

    Print the text on this pane's screen. With --lines, print the last N lines,
    including scrollback.

    Options:
      --lines <N>                     How many lines to print.""" + COMMON + """

    Examples:
      aether read
      aether read --lines 200 --pane 5F1C...""",
        "view": """usage: aether view

    List every pane: its id, its window, and its title. The focused pane in each
    window is marked with *, and your own pane with <.

    Options:""" + COMMON + """

    Example:
      aether view""",
        "zoom": """usage: aether zoom

    Make this pane fill its window. Run it again to put it back.

    Options:""" + COMMON + """

    Example:
      aether zoom""",
        "font": """usage: aether font [N | --delta N]

    Change the type size by N points. 0 resets it. Prints the new size.

    Options:
      --delta <N>                     Points to add. Negative makes it smaller.
      --json                          Print the raw reply.

    Examples:
      aether font 1
      aether font --delta -2
      aether font 0""",
        "status": """usage: aether status <working|blocked|done|error|idle> [message]

    Show a colored dot on this pane's header. The message appears when you point at it.

    Options:""" + COMMON + """

    Examples:
      aether status working "Running the test suite"
      aether status blocked "Waiting for your answer"
      aether status done""",
        "notify": """usage: aether notify <message>

    Post a macOS notification titled with this pane's title.

    Options:""" + COMMON + """

    Example:
      aether notify "Build finished"
    """.rstrip(),
        "title": """usage: aether title <text>

    Set this pane's title. Shells and programs may change it again.

    Example:
      aether title "API server"
    """.rstrip(),
        "close": """usage: aether close <pane-id>

    Close a pane that this pane opened with split, tab, or open.

    Options:""" + COMMON + """

    Example:
      id=$(aether split -- npm test) && ... && aether close "$id"
    """.rstrip(),
        "skill": """usage: aether skill

    Install the Aether skill into ~/.claude, ~/.cursor, and ~/.agents. Only tools
    that are already set up (their folder exists) get it; the rest are listed as skipped.

    Example:
      aether skill""",
        "help": """usage: aether help [command]

    Show help for aether or one command.""",
    }

    # Value flags take the next word. Bool flags take none.
    PLACE_VALUES = {"--split", "--ratio"}
    PLACE_BOOLS = {"--right", "--left", "--up", "--down", "--top", "--bottom", "--focus"}
    SPECS = {
        "split": (PLACE_VALUES | {"--pane"}, PLACE_BOOLS | {"--json"}, True),
        "tab": ({"--pane"}, {"--focus", "--json"}, True),
        "open": (PLACE_VALUES | {"--pane"}, PLACE_BOOLS | {"--json"}, False),
        "read": ({"--pane", "--lines"}, {"--json"}, False),
        "view": ({"--pane"}, {"--json"}, False),
        "zoom": ({"--pane"}, {"--json"}, False),
        "font": ({"--delta"}, {"--json"}, False),
        "status": ({"--pane"}, {"--json"}, False),
        "notify": ({"--pane"}, {"--json"}, False),
        "title": (set(), set(), False),
        "close": ({"--pane"}, {"--json"}, False),
        "skill": (set(), set(), False),
    }


    def parse(cmd, argv):
        values, bools, takes_command = SPECS[cmd]
        opts, positional, command = {}, [], None
        i = 0
        while i < len(argv):
            word = argv[i]
            if word == "--":
                if not takes_command:
                    positional.extend(argv[i + 1:])
                else:
                    command = argv[i + 1:]
                break
            if word in ("-h", "--help"):
                raise SystemExit(show(cmd))
            if word.startswith("-") and not NUMBER.match(word):
                name, eq, inline = word.partition("=")
                if name in values:
                    if eq:
                        opts[name] = inline
                    elif i + 1 < len(argv):
                        i += 1
                        opts[name] = argv[i]
                    else:
                        raise Usage(f"{name} needs a value.")
                elif name in bools and not eq:
                    opts[name] = True
                else:
                    raise Usage(f"unknown option {word} for `aether {cmd}`.")
            else:
                positional.append(word)
            i += 1
        return opts, positional, command


    def show(cmd):
        print(HELP.get(cmd, HELP[""]))
        return 0


    def direction(opts, positional):
        picked = [name[2:] for name in ("--right", "--left", "--up", "--down", "--top", "--bottom") if opts.get(name)]
        if "--split" in opts:
            picked.append(opts["--split"])
        if positional:
            picked.append(positional.pop(0))
        if len(picked) > 1:
            raise Usage("pick one side: " + ", ".join(picked) + ".")
        side = (picked[0] if picked else "right").lower()
        if side not in DIRECTIONS:
            raise Usage(f"unknown side {side}. Use right, left, up, or down.")
        return DIRECTIONS[side]


    def ratio(opts):
        raw = opts.get("--ratio")
        if raw is None:
            return None
        try:
            value = float(raw)
        except ValueError:
            raise Usage(f"--ratio must be a number, not {raw}.")
        if value <= 1:
            value *= 100
        if not 10 <= value <= 80:
            raise Usage("--ratio must be between 10 and 80.")
        return value


    def number(raw, name):
        try:
            return float(raw)
        except (TypeError, ValueError):
            raise Usage(f"{name} must be a number, not {raw}.")


    def web_address(target):
        if SCHEME.match(target):
            if not target.lower().startswith(("http://", "https://")):
                raise Usage("Aether shows web pages over http or https.")
            return target
        if os.path.exists(target):
            raise Usage(f"{target} is a file. Aether shows web pages over http or https, and PDFs with `aether open pdf`.")
        return "http://" + target


    def place(cmd, opts, positional, command):
        body = {"focus": bool(opts.get("--focus"))}
        if cmd == "tab":
            if positional:
                raise Usage(f"unexpected {positional[0]}. Put the command after --, like `aether tab -- htop`.")
        else:
            body["direction"] = direction(opts, positional if cmd == "split" else [])
            share = ratio(opts)
            if share is not None:
                body["ratio"] = share
        if cmd == "split" and positional:
            raise Usage(f"unexpected {positional[0]}. Put the command after --, like `aether split -- npm test`.")
        if len(command or []) == 1:
            body["command"] = command[0]
        elif command:
            body["command"] = " ".join(quote(word) for word in command)
        return body


    def quote(word):
        if word and re.match(r"^[A-Za-z0-9_@%+=:,./-]+$", word):
            return word
        return "'" + word.replace("'", "'\"'\"'") + "'"


    def credentials():
        import plistlib
        path = os.environ.get("AETHER_AGENT_PLIST") or os.path.expanduser("~/Library/Application Support/Aether/agent.plist")
        try:
            with open(path, "rb") as handle:
                data = plistlib.load(handle)
            return int(data["port"]), str(data["token"])
        except FileNotFoundError:
            raise Failure("Aether is not running. Open Aether and run this in one of its panes.")
        except Exception:
            raise Failure(f"could not read {path}. Quit and reopen Aether to rewrite it.")


    def request(path, body, pane):
        import socket, urllib.error, urllib.request
        if pane:
            body["pane"] = pane
        session = os.environ.get("AETHER_SESSION", "")
        if session:
            body["session"] = session
            payload = {"path": path, "body": body, "session": session}
            url = "http://127.0.0.1:7392/agent"
            headers = {"Authorization": "Bearer " + os.environ.get("AETHER_TOKEN", ""), "Content-Type": "application/json"}
        else:
            port, token = credentials()
            payload = body
            url = f"http://127.0.0.1:{port}{path}"
            headers = {"Authorization": token, "Content-Type": "application/json"}
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=8) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                message = json.loads(raw).get("error") or ""
            except Exception:
                message = raw.decode(errors="replace").strip()
            if error.code == 401:
                raise Failure("Aether turned this request away. Quit and reopen Aether to refresh the token.")
            raise Failure(message or f"Aether answered {error.code}.")
        except (urllib.error.URLError, ConnectionError) as error:
            reason = getattr(error, "reason", error)
            if isinstance(reason, (socket.timeout, TimeoutError)):
                raise Failure("Aether did not answer in time.")
            raise Failure("Aether is not running, or its control port is closed.")
        except (socket.timeout, TimeoutError):
            raise Failure("Aether did not answer in time.")
        try:
            reply = json.loads(raw)
        except Exception:
            raise Failure("Aether sent a reply that is not JSON.")
        if not isinstance(reply, dict):
            raise Failure("Aether sent an unexpected reply.")
        if reply.get("ok") is False:
            raise Failure(reply.get("error") or "Aether could not do that.")
        return reply


    def tty_write(text):
        try:
            with open("/dev/tty", "w") as tty:
                tty.write(text)
        except OSError:
            raise Failure("no terminal to write to. Run this inside an Aether pane.")


    def clean(text):
        return re.sub(r"[\x00-\x1f\x7f]", " ", text)


    def install_skill():
        import shutil
        home = os.path.expanduser("~")
        plist = os.environ.get("AETHER_AGENT_PLIST") or os.path.join(home, "Library/Application Support/Aether/agent.plist")
        candidates = [
            os.path.join(os.path.dirname(plist), "skill", "SKILL.md"),
            os.path.join(home, "Library/Application Support/Aether/skill/SKILL.md"),
            "/usr/local/share/aether/SKILL.md",
        ]
        source = next((path for path in candidates if os.path.isfile(path)), None)
        if not source:
            raise Failure("could not find the Aether skill. Open Aether once so it can write it.")
        installed, skipped = [], []
        for tool in (".claude", ".cursor", ".agents"):
            root = os.path.join(home, tool)
            if not os.path.isdir(root):
                skipped.append(root)
                continue
            dest = os.path.join(root, "skills", "aether")
            try:
                os.makedirs(dest, exist_ok=True)
                shutil.copy(source, os.path.join(dest, "SKILL.md"))
                installed.append(dest)
            except OSError as error:
                skipped.append(f"{root} ({error.strerror})")
        for dest in installed:
            print(f"installed {dest}")
        for root in skipped:
            print(f"skipped {root}")
        if not installed:
            print("No agent folders found. Create ~/.claude, ~/.cursor, or ~/.agents first.")


    def main(argv):
        if not argv or argv[0] in ("-h", "--help"):
            return show("")
        if argv[0] in ("--version", "-V", "version"):
            app = os.environ.get("TERM_PROGRAM_VERSION") if os.environ.get("TERM_PROGRAM") == "Aether" else None
            print(f"aether {VERSION}" + (f" (Aether {app})" if app else ""))
            return 0
        global CURRENT
        cmd, rest = argv[0], argv[1:]
        if cmd == "help":
            if rest and rest[0] not in HELP:
                raise Usage(f"no help for {rest[0]}.")
            return show(rest[0] if rest else "")
        if cmd not in SPECS:
            if cmd.startswith("-"):
                raise Usage(f"unknown option {cmd}.")
            raise Usage(f"unknown command {cmd}.")
        CURRENT = cmd
        opts, positional, command = parse(cmd, rest)
        pane = opts.get("--pane") or os.environ.get("AETHER_PANE", "")
        raw = opts.get("--json")

        def finish(reply, text=None):
            if raw:
                print(json.dumps(reply, indent=2))
            elif text:
                print(text)
            return 0

        if cmd in ("split", "tab"):
            reply = request("/" + cmd, place(cmd, opts, positional, command), pane)
            return finish(reply, reply.get("pane"))
        if cmd == "open":
            if not positional:
                raise Usage("say what to open, like `aether open localhost:3000`.")
            kind = None
            if positional[0] in ("web", "pdf"):
                kind = positional.pop(0)
            if len(positional) != 1:
                raise Usage("give one address or file to open.")
            target = positional[0]
            if kind is None:
                kind = "pdf" if target.lower().endswith(".pdf") and not SCHEME.match(target) else "web"
            if kind == "pdf":
                target = os.path.abspath(os.path.expanduser(target))
                if not os.path.isfile(target) and not os.environ.get("AETHER_SESSION"):
                    raise Failure(f"no such file: {target}")
            else:
                target = web_address(target)
            body = place(cmd, opts, [], None)
            body["kind"] = kind
            body["target"] = target
            reply = request("/open", body, pane)
            return finish(reply, reply.get("pane"))
        if cmd == "read":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            body = {}
            if "--lines" in opts:
                lines = number(opts["--lines"], "--lines")
                if lines < 1 or lines != int(lines):
                    raise Usage("--lines must be a whole number above 0.")
                body["lines"] = int(lines)
            reply = request("/read", body, pane)
            if raw:
                return finish(reply)
            sys.stdout.write(reply.get("text", "").rstrip("\n") + "\n")
            return 0
        if cmd == "view":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            reply = request("/view", {}, pane)
            rows = []
            for row in reply.get("panes", []):
                mark = ("*" if row.get("focused") else " ") + ("<" if row.get("id") == pane else " ")
                rows.append(f"{mark} {row.get('id', '')}  desk {str(row.get('desk', ''))[:8]}  {row.get('title', '')}")
            return finish(reply, "\n".join(rows))
        if cmd == "zoom":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            reply = request("/zoom", {}, pane)
            return finish(reply)
        if cmd == "font":
            if len(positional) > 1 or (positional and "--delta" in opts):
                raise Usage("give one size change, like `aether font 1`.")
            delta = number(opts.get("--delta", positional[0] if positional else "1"), "the size change")
            reply = request("/font", {"delta": delta}, "")
            return finish(reply, str(reply.get("size", "")))
        if cmd == "status":
            if not positional:
                raise Usage("say a state: " + ", ".join(STATES) + ".")
            state = positional[0].lower()
            if state not in STATES:
                raise Usage(f"unknown state {state}. Use " + ", ".join(STATES) + ".")
            message = " ".join(positional[1:])
            if pane and not os.environ.get("AETHER_SESSION"):
                reply = request("/status", {"state": state, "message": message}, pane)
                return finish(reply)
            sequence = "state=" + state
            if message:
                sequence += ":msg=" + base64.b64encode(message.encode()).decode()
            tty_write("\x1b]7501;" + sequence + "\x1b\\")
            return 0
        if cmd == "notify":
            if not positional:
                raise Usage("say what to notify, like `aether notify \"Build finished\"`.")
            reply = request("/notify", {"message": " ".join(positional)}, pane)
            return finish(reply)
        if cmd == "title":
            if not positional:
                raise Usage("give a title, like `aether title \"API server\"`.")
            tty_write("\x1b]2;" + clean(" ".join(positional)) + "\x07")
            return 0
        if cmd == "close":
            if len(positional) != 1:
                raise Usage("give the id of one pane you opened, like `aether close <id>`.")
            reply = request("/close", {"target": positional[0]}, pane)
            return finish(reply)
        if cmd == "skill":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            install_skill()
            return 0
        raise Usage(f"unknown command {cmd}.")


    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as error:
        print(f"aether: {error}", file=sys.stderr)
        print(f"Run `aether help {CURRENT}` for usage." if CURRENT else "Run `aether --help` for usage.", file=sys.stderr)
        sys.exit(2)
    except Failure as error:
        print(f"aether: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
    except Exception as error:
        print(f"aether: unexpected error: {error}", file=sys.stderr)
        sys.exit(1)
    PY
    """#

    static let skill = #"""
    ---
    name: aether
    description: Control the Aether terminal the agent is running in. Open panes beside you, show a page or PDF, read a pane's screen, show your status, and close panes you opened.
    ---

    You are in Aether when `AETHER_PANE` is set. Use the `aether` command to change the layout. Do not guess keystrokes for splits.

    Every command acts on your own pane (`AETHER_PANE`), not on whatever pane the person is typing in. Pass `--pane <id>` to act on another pane. Commands never move the keyboard focus or raise windows unless you pass `--focus`.

    - `aether split --right --ratio 30 -- npm run dev` opens a terminal beside you and prints its id. Sides: `--right`, `--left`, `--up`, `--down`. Ratio is the new pane's share, from 10 to 80. Pass one quoted string after `--` for pipes: `aether split --down -- 'make 2>&1 | tee build.log'`.
    - `aether tab -- command` adds a terminal to your window and prints its id.
    - `aether open localhost:3000 --right --ratio 40` shows a page beside you. Addresses without a scheme get `http://`.
    - `aether open docs/spec.pdf --down` shows a PDF. Relative paths are fine.
    - `aether read` prints your screen. `aether read --pane <id> --lines 200` prints the last 200 lines of another pane, scrollback included.
    - `aether view` lists panes: `*` marks the focused pane in each window, `<` marks you.
    - `aether status working "Running tests"` shows a dot on your pane's header. States: `working`, `blocked`, `done`, `error`, `idle`. The message shows when the person points at the dot.
    - `aether notify "Build finished"` posts a macOS notification.
    - `aether title "API server"` names your pane.
    - `aether close <id>` closes a pane you opened. Aether refuses panes you did not open.
    - `aether zoom` fills the window with your pane, or puts it back.
    - `aether font 1` or `aether font -1` changes the type size. `aether font 0` resets it.
    - `aether help <command>` shows options and examples. Add `--json` to get the raw reply.

    Exit codes: 0 worked, 1 Aether refused or is not running (the reason is on stderr), 2 bad arguments.

    "Beside you" means split your own pane. Leave focus alone unless asked. Close only panes you opened, and close them when you are done with them.
    """#
}
