import AppKit
import Foundation
import Network

/// Local control socket so an agent on this Mac can open panes, place them, and read the screen.
@MainActor
final class AgentDesk {
    static let shared = AgentDesk()
    private var listener: NWListener?
    private let token: String
    /// AETHER_PORT lets a second test copy run beside Aether and Aether Dev.
    static let port: UInt16 = ProcessInfo.processInfo.environment["AETHER_PORT"].flatMap(UInt16.init) ?? (System.isDev ? 17394 : 17393)
    static let routes: Set<String> = [
        "/tab", "/split", "/open", "/font", "/zoom", "/read", "/view",
        "/status", "/notify", "/close", "/title", "/send", "/wait",
        "/windows", "/move", "/order", "/find", "/screenshot", "/workspace",
        "/resize", "/layout", "/focus", "/window", "/tabs", "/tab-select", "/tab-rename",
        "/tab-close", "/tab-move", "/set",
    ]
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
        try? (AgentCLI.agents + "\n").write(to: skillDir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        AgentSkills.install(
            skill: AgentCLI.skill + "\n",
            agents: AgentCLI.agents + "\n",
            home: FileManager.default.homeDirectoryForCurrentUser,
            env: ProcessInfo.processInfo.environment,
            // Apps opened from Finder get a bare PATH, so look where agents usually install too.
            path: (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + System.home() + "/.local/bin"
        )
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

    static let cloudTerminalMissing = "That Cloud terminal isn't open on this Mac."

    /// The pane a request is about: the one running its Cloud session, else the one it names,
    /// else the focused pane of a named window, else the focused pane of the front window.
    /// Without `allowFocusedFallback`, as for requests from Cloud, only the session counts.
    static func target(
        pane: String?,
        session: String?,
        desks: [String: Desk],
        sessions: [String: String],
        keyDesk: String?,
        allowFocusedFallback: Bool = true,
        window: String? = nil,
        desk namedDesk: String? = nil
    ) -> Result<Target, AgentError> {
        func deskHolding(_ id: String) -> String? {
            desks.first { $0.value.panes[id] != nil }?.key
        }
        if let session, !session.isEmpty, let id = sessions.first(where: { $0.value == session })?.key, let deskID = deskHolding(id) {
            return .success(Target(desk: deskID, pane: id, explicit: true))
        }
        guard allowFocusedFallback else { return .failure(AgentError(cloudTerminalMissing)) }
        if let pane, !pane.isEmpty {
            switch resolvePane(pane, desks: desks) {
            case .success(let id):
                guard let deskID = deskHolding(id) else { return .failure(AgentError("No pane \(pane).")) }
                return .success(Target(desk: deskID, pane: id, explicit: true))
            case .failure(let error):
                return .failure(error)
            }
        }
        if let deskID = resolveDesk(window ?? namedDesk, desks: desks, keyDesk: keyDesk) {
            guard let focused = desks[deskID]?.focusedID else {
                return .failure(AgentError("No Aether window is open."))
            }
            return .success(Target(desk: deskID, pane: focused, explicit: false))
        }
        if window != nil || namedDesk != nil {
            return .failure(AgentError("No window \(window ?? namedDesk ?? "")."))
        }
        if desks.count == 1, let only = desks.keys.first, let focused = desks[only]?.focusedID {
            return .success(Target(desk: only, pane: focused, explicit: false))
        }
        guard let keyDesk, let focused = desks[keyDesk]?.focusedID else {
            if desks.count > 1 {
                return .failure(AgentError("Pass --pane, --window, or --desk. Several windows are open."))
            }
            return .failure(AgentError("No Aether window is open."))
        }
        return .success(Target(desk: keyDesk, pane: focused, explicit: false))
    }

    /// Exact id, or a unique prefix of at least 8 characters.
    static func resolvePane(_ raw: String, desks: [String: Desk]) -> Result<String, AgentError> {
        let all = desks.values.flatMap(\.panes.keys)
        if all.contains(raw) { return .success(raw) }
        let lower = raw.lowercased()
        let exact = all.filter { $0.lowercased() == lower }
        if exact.count == 1 { return .success(exact[0]) }
        guard raw.count >= 8 else { return .failure(AgentError("No pane \(raw).")) }
        let matches = all.filter { $0.lowercased().hasPrefix(lower) }
        if matches.count == 1 { return .success(matches[0]) }
        if matches.count > 1 { return .failure(AgentError("Pane \(raw) is ambiguous.")) }
        return .failure(AgentError("No pane \(raw)."))
    }

    /// `this` is the front window, `any` is the front window or the only one.
    static func resolveDesk(_ raw: String?, desks: [String: Desk], keyDesk: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let token = raw.lowercased()
        if token == "this" || token == "any" {
            if let keyDesk, desks[keyDesk] != nil { return keyDesk }
            return desks.count == 1 ? desks.keys.first : nil
        }
        if desks[raw] != nil { return raw }
        let matches = desks.keys.filter { $0.lowercased() == token || (raw.count >= 8 && $0.lowercased().hasPrefix(token)) }
        return matches.count == 1 ? matches[0] : nil
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
    # The copy in "Aether Dev/bin" talks to Aether Dev, not to Aether.
    if [ -z "${AETHER_AGENT_PLIST:-}" ] && [ -f "${0%/*}/../agent.plist" ]; then
      AETHER_AGENT_PLIST="${0%/*}/../agent.plist"
      export AETHER_AGENT_PLIST
    fi
    # The program goes in as -c, not on stdin, so stdin stays free for `aether mcp`.
    program=$(cat <<'PY'
    import base64, json, os, re, sys
    
    VERSION = "4"
    STATES = ("idle", "working", "blocked", "done", "error")
    DIRECTIONS = {"right": "right", "left": "left", "up": "top", "top": "top", "down": "bottom", "bottom": "bottom", "center": "right"}
    SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
    NUMBER = re.compile(r"^-?\d+(\.\d+)?$")
    PANE_ID = re.compile(r"^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
    PANE_PREFIX = re.compile(r"^[0-9A-Fa-f]{8,32}$")
    COMMANDS = (
        "split", "tab", "open", "read", "view", "zoom", "font", "status", "notify",
        "title", "close", "skill", "send", "run", "wait", "windows", "move", "order",
        "find", "screenshot", "workspace", "resize", "layout", "equalize", "focus", "window",
        "tabs", "tab-select", "tab-rename", "tab-close", "tab-move", "set", "imgcat", "hook", "mcp", "help",
    )
    
    
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
      --window <id|this|any>          Act in this window. `any` is the front window; with one window you can omit this.
      --desk <id>                     Same as --window.
      --json                          Print the raw reply."""
    
    HELP = {
        "": """usage: aether <command> [options]
    
    Control the Aether terminal. Commands act on your own pane ($AETHER_PANE)
    unless you pass --pane <id>. Outside Aether, with one window open, that
    window is used; with several, pass --pane, --window, or --desk.
    
    Commands:
      split       Open a terminal beside this pane.
      tab         Add a terminal to this tab group.
      workspace   Open a new tab group in this window.
      open        Show a web page or PDF beside this pane.
      read        Print this pane's screen.
      view        List the panes.
      windows     List the windows.
      send        Type into a pane, or send keys like ctrl+c.
      run         Run a command and wait until it finishes.
      wait        Block until a pane is idle or its job exits.
      find        Find panes by title or running command.
      move        Reorder a pane in its window.
      order       Set the pane order of a window.
      zoom        Make this pane fill its window, or put it back.
      resize      Move a pane's edge to make it bigger or smaller.
      layout      Arrange the window: tall, fat, grid, columns, rows, stack.
      equalize    Give every pane in the window the same share.
      focus       Move the keyboard into a pane.
      window      Resize, move, zoom, or full-screen a window.
      tabs        List the tab groups.
      tab-select  Show a tab group. Also tab-rename, tab-close, tab-move.
      font        Make the type bigger or smaller.
      set         Change a setting, like the theme or the glass.
      imgcat      Show an image inline in this pane.
      status      Show what you are doing on this pane's header.
      notify      Post a macOS notification.
      title       Set this pane's title.
      close       Close a pane that you opened.
      screenshot  Save a PNG of a pane.
      skill       Install the Aether skill and session hook for agents.
      hook        Print Aether context for an agent session (used by hooks).
      mcp         Speak MCP over stdin/stdout (one tool per command).
      help        Show help for a command.
    
    Options:
      -h, --help     Show help.
      --version      Show the version.
    
    Run `aether help <command>` for details and examples.""",
        "split": """usage: aether split [--right|--left|--up|--down] [--ratio N] [--focus] [--title T] [-- command ...]
    
    Open a terminal beside this pane. Prints the new pane's id. Words after --
    run in the new pane; pass one quoted string for pipes and other shell syntax.
    """ + PLACE + COMMON + """
          --title <text>                  Name the new pane.
    
    Examples:
      aether split --right --ratio 30 -- npm run dev
      aether split --down -- tail -f log.txt
      aether split --left --focus
      aether split --up -- 'make 2>&1 | tee build.log'""",
        "tab": """usage: aether tab [--focus] [--title T] [-- command ...]
    
    Add a terminal to this pane's window. Prints the new pane's id. Words after --
    run in the new pane.
    
    Options:
          --focus                         Move the keyboard into the new pane.
          --title <text>                  Name the new pane.""" + COMMON + """
    
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
        "read": """usage: aether read [pane-id] [--lines N]
    
    Print the text on this pane's screen. With --lines, print the last N lines,
    including scrollback. A pane id may be positional or --pane.
    
    Options:
      --lines <N>                     How many lines to print.""" + COMMON + """
    
    Examples:
      aether read
      aether read 50BBAE3B --lines 200""",
        "view": """usage: aether view
    
    List every pane: its id, window, title, and running command. The focused pane
    in each window is marked with *, and your own pane with <.
    
    Options:""" + COMMON + """
    
    Example:
      aether view
      aether view --json""",
        "windows": """usage: aether windows
    
    List every Aether window and how many panes it has.
    
    Options:
      --json                          Print the raw reply.
    
    Example:
      aether windows""",
        "send": """usage: aether send [pane-id] [<text> | --keys <chord>] [--enter]
    
    Inject keystrokes into a pane as if they were typed. --keys takes named chords
    separated by commas: ctrl+c, enter, up, tab, esc, ctrl+d.
    
    Options:
      --keys <chord>                  Send a key or chord instead of text.
      --enter                         Press return after the text.""" + COMMON + """
    
    Examples:
      aether send --keys ctrl+c
      aether send 50BBAE3B y --enter
      aether send --pane 50BBAE3B --keys ctrl+c,enter""",
        "run": """usage: aether run [--pane <id>] [--title T] [--timeout N] [--] <command...>
    
    Run a command and wait until it finishes. Prints the command's output as it
    appears, then exits with the command's status. Without --pane, opens a new pane
    and closes it when the command ends, unless you pass --keep.
    SIGINT (Ctrl-C on aether run) sends ctrl+c to the pane's job.
    
    Options:
      --title <text>                  Name the pane.
      --timeout <seconds>             Give up after this many seconds.
      --focus                         Move the keyboard into the pane.
      --keep                          Leave the new pane open after the command ends.""" + COMMON + """
    
    Examples:
      aether run -- make test
      aether run --pane 50BBAE3B -- npm test""",
        "wait": """usage: aether wait [pane-id] [--until-idle|--exit] [--timeout N]
    
    Block until the pane's shell is idle (prompt at the bottom) or its job exits.
    
    Options:
      --until-idle                    Return when the shell is at a prompt.
      --exit, --until-exit            Return when the pane's process exits.
      --timeout <seconds>             Give up after this many seconds.""" + COMMON + """
    
    Examples:
      aether wait 50BBAE3B --exit
      aether wait --until-idle --timeout 30""",
        "find": """usage: aether find [--title T] [--command T]
    
    Find panes whose title or running command contains the text.
    
    Options:
      --title <text>                  Match the pane title.
      --command <text>                Match the running command.""" + COMMON + """
    
    Examples:
      aether find --command nmap
      aether find --title API""",
        "move": """usage: aether move [pane-id] (--before <id>|--after <id>|--index N)
    
    Move a pane in its window.
    
    Options:
      --before <id>                   Place it before this pane.
      --after <id>                    Place it after this pane.
      --index <N>                     Place it at this 0-based index.""" + COMMON + """
    
    Examples:
      aether move 50BBAE3B --before AABBCCDD
      aether move --index 0""",
        "order": """usage: aether order <pane-id> <pane-id> ...
    
    Set the pane order of a window. Pass every pane in that window, once.
    
    Options:""" + COMMON + """
    
    Example:
      aether order 50BBAE3B AABBCCDD""",
        "zoom": """usage: aether zoom [pane-id]
    
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
        "title": """usage: aether title [pane-id] <text>
    
    Set this pane's title.
    
    Options:""" + COMMON + """
    
    Example:
      aether title "API server"
      aether title 50BBAE3B "port sweep"
    """.rstrip(),
        "close": """usage: aether close <pane-id>
    
    Close a pane that this pane opened with split, tab, or open.
    
    Options:""" + COMMON + """
    
    Example:
      id=$(aether split -- npm test) && ... && aether close "$id"
    """.rstrip(),
        "screenshot": """usage: aether screenshot [pane-id] [--out <path>]
    
    Save a PNG of the pane. Prints the path.
    
    Options:
      --out <path>                    Where to write the PNG.""" + COMMON + """
    
    Example:
      aether screenshot --out /tmp/pane.png""",
        "workspace": """usage: aether workspace [--title T] [-- command ...]
    
    Open a new tab group in this window, with one blank terminal. Other tab groups
    keep running. Prints the new tab id.
    
    Options:
          --title <text>                  Name the tab.""" + COMMON + """
    
    Examples:
      aether workspace --title school
      aether workspace -- claude""",
        "hook": """usage: aether hook
    
    Print a short briefing for an agent session started inside Aether. Session
    hooks call this. Outside Aether it prints nothing.
    
    Example:
      aether hook""",
        "skill": """usage: aether skill [--project]
    
    Install the Aether skill and a session hook into every agent home Aether finds
    (~/.claude, ~/.cursor, ~/.codex, ~/.agents, ~/.gemini, ~/.opencode). Aether also
    does this when it launches. --project writes AGENTS.md in this folder.
    
    Example:
      aether skill""",
        "mcp": """usage: aether mcp
    
    Speak the Model Context Protocol on stdin/stdout. Each aether command is one
    tool, so an MCP client can call send, run, wait, read, and the rest natively.
    
    Example:
      aether mcp""",
        "resize": """usage: aether resize [pane-id] (--grow <edge> | --shrink <edge>) [--by N]
    
    Move one edge of a pane. --grow right pushes its right edge out; --shrink right
    pulls it in. Edges: left, right, up, down. N is percent of the split (default 5).
    
    Options:
      --grow <edge>                   Push this edge outward.
      --shrink <edge>                 Pull this edge inward.
      --by <N>                        How far, in percent. Default: 5.""" + COMMON + """
    
    Examples:
      aether resize 50BBAE3B --grow right --by 10
      aether resize --shrink down""",
        "layout": """usage: aether layout <tall|fat|grid|columns|rows|stack|next|prev|equalize>
    
    Arrange the panes of a window. Prints the layout.
    
    Options:""" + COMMON + """
    
    Examples:
      aether layout grid
      aether layout next --window any""",
        "equalize": """usage: aether equalize
    
    Give every pane in the window the same share.
    
    Options:""" + COMMON + """
    
    Example:
      aether equalize""",
        "focus": """usage: aether focus <pane-id>
    
    Move the keyboard into a pane, showing its tab group and bringing its window
    to the front.
    
    Options:""" + COMMON + """
    
    Example:
      aether focus 50BBAE3B""",
        "window": """usage: aether window [--size WxH] [--position X,Y] [--zoom] [--fullscreen] [--front]
    
    Resize or move a window. Points are measured from the top-left of the main
    screen. Prints the window's frame. --zoom and --fullscreen toggle.
    
    Options:
      --size <WxH>                    New size in points, like 1200x800.
      --position <X,Y>                New top-left corner, like 40,60.
      --zoom                          Toggle zoom (the green button).
      --fullscreen                    Toggle full screen.
      --front                         Bring the window to the front.""" + COMMON + """
    
    Examples:
      aether window --size 1400x900 --position 0,40
      aether window --fullscreen""",
        "tabs": """usage: aether tabs
    
    List every tab group: index, id, window, panes, and title. The shown tab is
    marked with *.
    
    Options:
      --json                          Print the raw reply.
    
    Example:
      aether tabs""",
        "tab-select": """usage: aether tab-select <tab-id|index>
    
    Show a tab group. An index counts from 0 in your window (or --window).
    
    Options:""" + COMMON + """
    
    Example:
      aether tab-select 1""",
        "tab-rename": """usage: aether tab-rename <tab-id|index> <name>
    
    Name a tab group. An empty name goes back to the automatic one.
    
    Options:""" + COMMON + """
    
    Example:
      aether tab-rename 0 school""",
        "tab-close": """usage: aether tab-close <tab-id|index>
    
    Close a tab group and every pane in it, without asking.
    
    Options:""" + COMMON + """
    
    Example:
      aether tab-close 2""",
        "tab-move": """usage: aether tab-move <tab-id|index> --index N
    
    Move a tab group to position N (from 0) in its window.
    
    Options:
      --index <N>                     Where it goes.""" + COMMON + """
    
    Example:
      aether tab-move 2 --index 0""",
        "set": """usage: aether set [key] [value]
    
    Change a setting. With no key, print the settings agents may change.
    Keys: themeName, glass, shade, text, fontSize, fontFamily, lineHeight,
    cornerRadius, gap, cursorShape, cursorBlink, copyOnSelect, bell, blurAmount,
    minimumContrast, notifyOnFinish, gpuRendering.
    
    Options:
      --json                          Print the raw reply.
    
    Examples:
      aether set
      aether set themeName Dracula
      aether set fontSize 15""",
        "imgcat": """usage: aether imgcat <file> [--width N]
    
    Draw an image (PNG, JPEG, GIF) inline in the pane you run it in, with the
    iTerm2 image protocol. Aether also draws kitty graphics and sixel.
    
    Options:
      --width <N>                     Width in cells. Default: the image's own size.
    
    Examples:
      aether imgcat chart.png
      aether run --keep -- aether imgcat /tmp/shot.png --width 40""",
        "help": """usage: aether help [command]
    
    Show help for aether or one command.""",
    }
    
    PLACE_VALUES = {"--split", "--ratio"}
    PLACE_BOOLS = {"--right", "--left", "--up", "--down", "--top", "--bottom", "--focus"}
    TARGET = {"--pane", "--window", "--desk"}
    JSON = {"--json"}
    SPECS = {
        "split": (PLACE_VALUES | TARGET | {"--title"}, PLACE_BOOLS | JSON, True),
        "tab": (TARGET | {"--title"}, {"--focus"} | JSON, True),
        "open": (PLACE_VALUES | TARGET, PLACE_BOOLS | JSON, False),
        "read": (TARGET | {"--lines"}, JSON, False),
        "view": (TARGET, JSON, False),
        "zoom": (TARGET, JSON, False),
        "font": ({"--delta"}, JSON, False),
        "status": (TARGET, JSON, False),
        "notify": (TARGET, JSON, False),
        "title": (TARGET, JSON, False),
        "close": (TARGET, JSON, False),
        "skill": (set(), {"--project"} | JSON, False),
        "workspace": (TARGET | {"--title"}, JSON, True),
        "hook": (set(), set(), False),
        "send": (TARGET | {"--keys"}, {"--enter"} | JSON, False),
        "run": (TARGET | {"--title", "--timeout"}, {"--focus", "--keep"} | JSON, True),
        "wait": (TARGET | {"--timeout"}, {"--until-idle", "--exit", "--until-exit"} | JSON, False),
        "windows": (set(), JSON, False),
        "move": (TARGET | {"--before", "--after", "--index"}, JSON, False),
        "order": (TARGET, JSON, False),
        "find": (TARGET | {"--title", "--command"}, JSON, False),
        "screenshot": (TARGET | {"--out"}, JSON, False),
        "mcp": (set(), set(), False),
        "resize": (TARGET | {"--grow", "--shrink", "--by"}, JSON, False),
        "layout": (TARGET, JSON, False),
        "equalize": (TARGET, JSON, False),
        "focus": (TARGET, JSON, False),
        "window": (TARGET | {"--size", "--position"}, {"--zoom", "--fullscreen", "--front"} | JSON, False),
        "tabs": (set(), JSON, False),
        "tab-select": (TARGET, JSON, False),
        "tab-rename": (TARGET, JSON, False),
        "tab-close": (TARGET, JSON, False),
        "tab-move": (TARGET | {"--index"}, JSON, False),
        "set": (set(), JSON, False),
        "imgcat": ({"--width"}, set(), False),
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
                        raise Usage(f"{name} needs a value. See `aether help {cmd}`.")
                elif name in bools and not eq:
                    opts[name] = True
                else:
                    raise Usage(f"unknown option {word} for `aether {cmd}`. See `aether help {cmd}`.")
            else:
                positional.append(word)
            i += 1
        return opts, positional, command
    
    
    def show(cmd):
        print(HELP.get(cmd, HELP[""]))
        return 0
    
    
    def is_pane_id(word):
        if PANE_ID.match(word):
            return True
        compact = word.replace("-", "")
        return bool(PANE_PREFIX.match(compact))
    
    
    def take_pane(positional, opts, env=True):
        pane = opts.get("--pane") or (os.environ.get("AETHER_PANE", "") if env else "")
        if positional and is_pane_id(positional[0]):
            pane = positional.pop(0)
        return pane
    
    
    def not_a_pane(word):
        return Usage(f"{word} is not a pane id. Ids look like 50BBAE3B; `aether view` lists them.")
    
    
    def targeting(opts, pane):
        body = {}
        if pane:
            body["pane"] = pane
        if opts.get("--window"):
            body["window"] = opts["--window"]
        if opts.get("--desk"):
            body["desk"] = opts["--desk"]
        return body
    
    
    def merge(base, extra):
        body = dict(base)
        body.update(extra)
        return body
    
    
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
        if opts.get("--title"):
            body["title"] = opts["--title"]
        if cmd == "tab":
            if positional:
                raise Usage(
                    f"unexpected {positional[0]}. "
                    f"Pass a pane as --pane {positional[0]}, or put the command after --, like `aether tab -- htop`."
                )
        else:
            body["direction"] = direction(opts, positional if cmd == "split" else [])
            share = ratio(opts)
            if share is not None:
                body["ratio"] = share
        if cmd == "split" and positional:
            raise Usage(
                f"unexpected {positional[0]}. "
                f"Pass a pane as --pane {positional[0]}, or put the command after --, like `aether split -- npm test`."
            )
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
    
    
    def request(path, body, pane=None):
        import socket, urllib.error, urllib.request
        if pane:
            body.setdefault("pane", pane)
        wait = 8
        session = os.environ.get("AETHER_SESSION", "")
        if session:
            body["session"] = session
            payload = {"path": path, "body": body, "session": session}
            url = "http://127.0.0.1:7392/agent"
            if body.get("command") or path in ("/view", "/windows", "/find", "/send"):
                wait = 125
            headers = {"Authorization": "Bearer " + os.environ.get("AETHER_TOKEN", ""), "Content-Type": "application/json"}
        else:
            port, token = credentials()
            payload = body
            url = f"http://127.0.0.1:{port}{path}"
            headers = {"Authorization": token, "Content-Type": "application/json"}
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=wait) as response:
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
    
    
    def watch(pane, until, timeout, since=None, after_prompts=None, skip=False):
        """Poll until the pane is idle or exited. With `since`, stream its new lines to stdout."""
        import signal, time
        deadline = time.monotonic() + timeout if timeout else None
        sent_interrupt = False
        saw_busy = after_prompts is None
    
        def handle(_sig, _frame):
            nonlocal sent_interrupt
            if sent_interrupt:
                raise KeyboardInterrupt
            sent_interrupt = True
            try:
                request("/send", merge(targeting({}, pane), {"keys": "ctrl+c"}), pane)
            except Exception:
                raise KeyboardInterrupt
    
        def pump(final, prompt):
            nonlocal since, skip
            body = {"since": since, "final": final, "prompt": prompt, "skip": skip}
            part = request("/read", merge(targeting({}, pane), body), pane)
            if part.get("text"):
                skip = False
                sys.stdout.write(part["text"])
                sys.stdout.flush()
            if isinstance(part.get("next"), int):
                since = part["next"]
    
        old = signal.signal(signal.SIGINT, handle)
        try:
            while True:
                state = request("/wait", targeting({}, pane), pane)
                exited = bool(state.get("exited"))
                idle = bool(state.get("idle"))
                if not idle and not exited:
                    saw_busy = True
                prompts = state.get("prompts")
                prompts = prompts if isinstance(prompts, int) else 0
                integrated = bool(state.get("integrated"))
                if until == "exit" or exited:
                    done = exited
                elif after_prompts is None:
                    done = idle
                elif integrated:
                    done = prompts > after_prompts
                else:
                    done = idle and saw_busy
                if since is not None:
                    pump(done and exited, done and not exited)
                if done:
                    if sent_interrupt:
                        state["interrupted"] = True
                    return state
                if deadline is not None and time.monotonic() >= deadline:
                    raise Failure("timed out waiting for that pane.")
                time.sleep(0.1)
        finally:
            signal.signal(signal.SIGINT, old)
    
    
    def show_hook():
        pane = os.environ.get("AETHER_PANE", "")
        if not pane:
            return 0
        print(
            "You are in Aether, a native macOS terminal.\n"
            f"This pane's id is {pane}. The `aether` CLI is on PATH.\n"
            "Use it to split, open workspace tabs, send keys, run commands, and read screens:\n"
            "  aether run -- make test            run in a new pane, stream output, exit with its status\n"
            "  id=$(aether tab --title job)       open a shell pane and print its id\n"
            "  aether send $id 'npm test' --enter type into a pane; --keys ctrl+c interrupts it\n"
            "  aether wait $id --until-idle       block until its prompt is back\n"
            "  aether read $id --lines 50         print its output\n"
            "  aether view                        list panes and what they are running\n"
            "Do not guess tmux, iTerm, or Terminal.app keystrokes.\n"
            "`aether workspace` is a new tab group; `aether tab` is a new pane in this group.\n"
            "Run `aether help` for the rest."
        )
        return 0
    
    
    def install_skill(project=False):
        import shutil
        home = os.path.expanduser("~")
        plist = os.environ.get("AETHER_AGENT_PLIST") or os.path.join(home, "Library/Application Support/Aether/agent.plist")
        support = os.path.dirname(plist)
        skill_candidates = [
            os.path.join(support, "skill", "SKILL.md"),
            os.path.join(home, "Library/Application Support/Aether/skill/SKILL.md"),
            "/usr/local/share/aether/SKILL.md",
        ]
        agents_candidates = [
            os.path.join(support, "skill", "AGENTS.md"),
            os.path.join(home, "Library/Application Support/Aether/skill/AGENTS.md"),
            "/usr/local/share/aether/AGENTS.md",
        ]
        source = next((path for path in skill_candidates if os.path.isfile(path)), None)
        agents = next((path for path in agents_candidates if os.path.isfile(path)), None)
        if not source:
            raise Failure("could not find the Aether skill. Open Aether once so it can write it.")
        installed, skipped = [], []
        for tool in (".claude", ".cursor", ".agents", ".codex", ".gemini", ".opencode"):
            root = os.path.join(home, tool)
            if not os.path.isdir(root):
                skipped.append(root)
                continue
            dest = os.path.join(root, "skills", "aether")
            try:
                os.makedirs(dest, exist_ok=True)
                shutil.copy(source, os.path.join(dest, "SKILL.md"))
                if agents:
                    shutil.copy(agents, os.path.join(dest, "AGENTS.md"))
                installed.append(dest)
            except OSError as error:
                skipped.append(f"{root} ({error.strerror})")
        if project and agents:
            cwd_agents = os.path.join(os.getcwd(), "AGENTS.md")
            try:
                shutil.copy(agents, cwd_agents)
                installed.append(cwd_agents)
            except OSError as error:
                skipped.append(f"{cwd_agents} ({error.strerror})")
        for dest in installed:
            print(f"installed {dest}")
        for root in skipped:
            print(f"skipped {root}")
        if not installed:
            print("No agent folders found. Create ~/.claude, ~/.cursor, or ~/.agents first.")
    
    
    def mcp():
        # MCP's stdio transport is one JSON-RPC message per line. Content-Length framing is accepted too.
        framed = False
    
        def read_message():
            nonlocal framed
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line.strip() == b"":
                    continue
                if line.lower().startswith(b"content-length:"):
                    framed = True
                    length = int(line.split(b":", 1)[1].strip() or 0)
                    while sys.stdin.buffer.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    line = sys.stdin.buffer.read(length)
                try:
                    return json.loads(line)
                except ValueError:
                    write_message({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
    
        def write_message(message):
            raw = json.dumps(message, separators=(",", ":")).encode()
            if framed:
                sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode() + raw)
            else:
                sys.stdout.buffer.write(raw + b"\n")
            sys.stdout.buffer.flush()
    
        def tools():
            args = {
                "type": "array",
                "items": {"type": "string"},
                "description": "Arguments as on the command line, after the command name. Example: [\"50BBAE3B\", \"--lines\", \"50\"].",
            }
            return [
                {
                    "name": name,
                    "description": HELP.get(name, ""),
                    "inputSchema": {"type": "object", "properties": {"args": args}, "additionalProperties": True},
                }
                for name in COMMANDS if name not in ("help", "mcp", "hook", "imgcat")
            ]
    
        def call(name, arguments):
            import contextlib, io
            argv = [name]
            extra = (arguments or {}).get("args")
            if isinstance(extra, str):
                extra = [extra]
            for key, value in (arguments or {}).items():
                if key == "args":
                    continue
                flag = "--" + key.replace("_", "-")
                if value is True:
                    argv.append(flag)
                elif value is False or value is None:
                    continue
                elif key in ("command", "text", "message", "argv") and isinstance(value, list):
                    argv.append("--")
                    argv.extend(str(item) for item in value)
                elif key in ("command", "text", "message") and isinstance(value, str) and name in ("run", "send", "notify", "title", "status"):
                    argv.extend(["--", value] if name == "run" else [value])
                else:
                    argv.extend([flag, str(value)])
            if isinstance(extra, list):
                argv[1:1] = [str(item) for item in extra]
            out, err = io.StringIO(), io.StringIO()
            code = 0
            try:
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = main(argv)
            except SystemExit as error:
                code = error.code if isinstance(error.code, int) else (0 if not error.code else 1)
            except Usage as error:
                err.write(f"aether: {error}\n")
                code = 2
            except Failure as error:
                err.write(f"aether: {error}\n")
                code = 1
            text = (out.getvalue() + err.getvalue()).rstrip()
            if not text:
                text = f"exit {code}"
            result = {"content": [{"type": "text", "text": text}]}
            if code not in (0, None):
                result["isError"] = True
            return result
    
        while True:
            message = read_message()
            if message is None:
                return 0
            if not isinstance(message, dict):
                continue
            method = message.get("method")
            ident = message.get("id")
            if method == "initialize":
                write_message({"jsonrpc": "2.0", "id": ident, "result": {
                    "protocolVersion": (message.get("params") or {}).get("protocolVersion") or "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "aether", "version": VERSION},
                }})
            elif method == "ping":
                write_message({"jsonrpc": "2.0", "id": ident, "result": {}})
            elif ident is None:
                continue
            elif method == "tools/list":
                write_message({"jsonrpc": "2.0", "id": ident, "result": {"tools": tools()}})
            elif method == "tools/call":
                params = message.get("params") or {}
                try:
                    result = call(params.get("name"), params.get("arguments") or {})
                    write_message({"jsonrpc": "2.0", "id": ident, "result": result})
                except SystemExit as error:
                    write_message({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": f"exit {error.code}"}]}})
                except Exception as error:
                    write_message({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": str(error)}})
            elif ident is not None:
                write_message({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": f"unknown method {method}"}})
    
    
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
                raise Usage(f"no help for {rest[0]}. Commands: " + ", ".join(COMMANDS) + ".")
            return show(rest[0] if rest else "")
        if cmd == "mcp":
            return mcp()
        if cmd in ("hook", "context"):
            return show_hook()
        if cmd not in SPECS:
            if cmd.startswith("-"):
                raise Usage(f"unknown option {cmd}.")
            raise Usage(f"unknown command {cmd}. Commands: " + ", ".join(COMMANDS) + ".")
        CURRENT = cmd
        opts, positional, command = parse(cmd, rest)
        if cmd == "close":
            pane = opts.get("--pane") or os.environ.get("AETHER_PANE", "")
        elif cmd == "run":
            pane = take_pane(positional, opts, env=False)
        elif cmd in ("order", "tab-select", "tab-rename", "tab-close", "tab-move"):
            pane = opts.get("--pane") or os.environ.get("AETHER_PANE", "")
        else:
            pane = take_pane(positional, opts)
        raw = opts.get("--json")
    
        def finish(reply, text=None):
            if raw:
                print(json.dumps(reply, indent=2))
            elif text:
                print(text)
            return 0
    
        def call(path, body=None):
            payload = targeting(opts, pane)
            if body:
                payload.update(body)
            return request(path, payload, pane)
    
        if cmd in ("split", "tab"):
            reply = call("/" + cmd, place(cmd, opts, positional, command))
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
            reply = call("/open", body)
            return finish(reply, reply.get("pane"))
        if cmd == "read":
            if positional:
                raise not_a_pane(positional[0])
            body = {}
            if "--lines" in opts:
                lines = number(opts["--lines"], "--lines")
                if lines < 1 or lines != int(lines):
                    raise Usage("--lines must be a whole number above 0.")
                body["lines"] = int(lines)
            reply = call("/read", body)
            if raw:
                return finish(reply)
            sys.stdout.write(reply.get("text", "").rstrip("\n") + "\n")
            return 0
        if cmd == "view":
            if positional:
                raise Usage(f"unexpected {positional[0]}. `aether view` lists every pane.")
            reply = call("/view", {})
            rows = []
            for row in reply.get("panes", []):
                mark = ("*" if row.get("focused") else " ") + ("<" if row.get("id") == pane else " ")
                running = row.get("command") or ""
                extra = f"  {running}" if running else ""
                rows.append(f"{mark} {row.get('id', '')}  desk {str(row.get('desk', ''))[:8]}  {row.get('title', '')}{extra}")
            return finish(reply, "\n".join(rows))
        if cmd == "windows":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            reply = request("/windows", {}, None)
            rows = []
            for row in reply.get("windows", []):
                mark = "*" if row.get("focused") else " "
                rows.append(f"{mark} {row.get('id', '')}  {row.get('panes', 0)} panes  {row.get('title', '')}")
            return finish(reply, "\n".join(rows))
        if cmd == "zoom":
            if positional:
                raise not_a_pane(positional[0])
            reply = call("/zoom", {})
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
                reply = call("/status", {"state": state, "message": message})
                return finish(reply)
            sequence = "state=" + state
            if message:
                sequence += ":msg=" + base64.b64encode(message.encode()).decode()
            tty_write("\x1b]7501;" + sequence + "\x1b\\")
            return 0
        if cmd == "notify":
            if not positional:
                raise Usage("say what to notify, like `aether notify \"Build finished\"`.")
            reply = call("/notify", {"message": " ".join(positional)})
            return finish(reply)
        if cmd == "title":
            if not positional:
                raise Usage("give a title, like `aether title \"API server\"`.")
            reply = call("/title", {"text": clean(" ".join(positional))})
            return finish(reply, reply.get("title"))
        if cmd == "close":
            if len(positional) != 1:
                raise Usage("give the id of one pane you opened, like `aether close <id>`.")
            reply = call("/close", {"target": positional[0]})
            return finish(reply)
        if cmd == "send":
            body = {}
            if opts.get("--keys"):
                body["keys"] = opts["--keys"]
                if positional:
                    raise Usage(f"unexpected {positional[0]}. With --keys, do not also pass text.")
            else:
                if not positional:
                    raise Usage("give text or --keys, like `aether send --keys ctrl+c` or `aether send y --enter`.")
                body["text"] = " ".join(positional)
            if opts.get("--enter"):
                body["enter"] = True
            reply = call("/send", body)
            return finish(reply)
        if cmd == "run":
            words = list(command) if command is not None else list(positional)
            if not words:
                raise Usage("give a command, like `aether run -- make test`.")
            line = words[0] if len(words) == 1 else " ".join(quote(word) for word in words)
            timeout = number(opts["--timeout"], "--timeout") if "--timeout" in opts else None
            if pane:
                before = call("/wait", {})
                if before.get("exited"):
                    raise Failure("that pane has exited. Run without --pane to open a new one.")
                after = before.get("prompts") if isinstance(before.get("prompts"), int) else 0
                start = call("/read", {"since": None}).get("cursor")
                call("/send", {"text": line, "enter": True})
                if opts.get("--title"):
                    call("/title", {"text": opts["--title"]})
                since = None if raw or not isinstance(start, int) else start + 1
                state = watch(pane, "idle", timeout, since=since, after_prompts=after, skip=True)
                if raw:
                    return finish(state)
                code = state.get("lastStatus")
                if not isinstance(code, int):
                    code = state.get("exitCode")
                return int(code) if isinstance(code, int) else 0
            body = place("tab", opts, [], words)
            body["command"] = line
            reply = call("/tab", body)
            target = reply.get("pane") or pane
            state = watch(target, "exit", timeout, since=None if raw else 0)
            if raw:
                print(json.dumps(state, indent=2))
            if not opts.get("--keep"):
                try:
                    request("/close", {"target": target}, None)
                except Failure:
                    pass
            if isinstance(state.get("exitCode"), int):
                return int(state["exitCode"])
            # No status means a signal ended it: ours (ctrl+c) or someone else's.
            return 130 if state.get("interrupted") else 1
        if cmd == "wait":
            if positional:
                raise not_a_pane(positional[0])
            if opts.get("--until-idle") and (opts.get("--exit") or opts.get("--until-exit")):
                raise Usage("pick one of --until-idle or --exit.")
            until = "exit" if (opts.get("--exit") or opts.get("--until-exit")) else "idle"
            timeout = number(opts["--timeout"], "--timeout") if "--timeout" in opts else None
            state = watch(pane, until, timeout)
            return finish(state)
        if cmd == "find":
            if positional:
                raise Usage("pass --title or --command, like `aether find --command nmap`.")
            if "--title" not in opts and "--command" not in opts:
                raise Usage("pass --title or --command, like `aether find --command nmap`.")
            body = {}
            if "--title" in opts:
                body["title"] = opts["--title"]
            if "--command" in opts:
                body["command"] = opts["--command"]
            reply = request("/find", body, None)
            rows = [f"{row.get('id', '')}  {row.get('title', '')}  {row.get('command', '')}".rstrip() for row in reply.get("panes", [])]
            return finish(reply, "\n".join(rows))
        if cmd == "move":
            if positional:
                raise not_a_pane(positional[0])
            body = {}
            if "--before" in opts:
                body["before"] = opts["--before"]
            if "--after" in opts:
                body["after"] = opts["--after"]
            if "--index" in opts:
                index = number(opts["--index"], "--index")
                if index != int(index) or index < 0:
                    raise Usage("--index must be a whole number 0 or above.")
                body["index"] = int(index)
            if not body:
                raise Usage("pass --before, --after, or --index.")
            reply = call("/move", body)
            order = " ".join(reply.get("order") or [])
            return finish(reply, order)
        if cmd == "order":
            if len(positional) < 2:
                raise Usage("give every pane in the window, like `aether order <id> <id> ...`.")
            reply = request("/order", merge(targeting(opts, pane), {"panes": positional}), None)
            order = " ".join(reply.get("order") or [])
            return finish(reply, order)
        if cmd == "screenshot":
            if positional:
                raise not_a_pane(positional[0])
            body = {}
            if "--out" in opts:
                body["path"] = os.path.abspath(os.path.expanduser(opts["--out"]))
            reply = call("/screenshot", body)
            return finish(reply, reply.get("path"))
        if cmd == "resize":
            if positional:
                raise not_a_pane(positional[0])
            if ("--grow" in opts) == ("--shrink" in opts):
                raise Usage("pass --grow <edge> or --shrink <edge>, like `aether resize --grow right`.")
            edge = (opts.get("--grow") or opts.get("--shrink")).lower()
            edge = {"top": "up", "bottom": "down"}.get(edge, edge)
            if edge not in ("left", "right", "up", "down"):
                raise Usage(f"unknown edge {edge}. Use left, right, up, or down.")
            by = number(opts.get("--by", "5"), "--by")
            reply = call("/resize", {"edge": edge, "by": by if "--grow" in opts else -by})
            return finish(reply)
        if cmd in ("layout", "equalize"):
            if cmd == "equalize":
                if positional:
                    raise not_a_pane(positional[0])
                name = "equalize"
            elif len(positional) != 1:
                raise Usage("give one layout: tall, fat, grid, columns, rows, stack, next, prev, or equalize.")
            else:
                name = positional[0]
            reply = call("/layout", {"layout": name})
            return finish(reply, reply.get("layout") if cmd == "layout" else None)
        if cmd == "focus":
            if positional:
                raise not_a_pane(positional[0])
            if not pane:
                raise Usage("say which pane, like `aether focus 50BBAE3B`.")
            return finish(call("/focus", {}))
        if cmd == "window":
            if positional:
                raise Usage(f"unexpected {positional[0]}. See `aether help window`.")
            body = {}
            if "--size" in opts:
                match = re.match(r"^(\d+)[x,](\d+)$", opts["--size"].lower())
                if not match:
                    raise Usage("--size looks like 1200x800.")
                body["width"], body["height"] = int(match.group(1)), int(match.group(2))
            if "--position" in opts:
                match = re.match(r"^(-?\d+)[,x](-?\d+)$", opts["--position"].lower())
                if not match:
                    raise Usage("--position looks like 40,60.")
                body["x"], body["y"] = int(match.group(1)), int(match.group(2))
            for flag in ("--zoom", "--fullscreen", "--front"):
                if opts.get(flag):
                    body[flag[2:]] = True
            reply = call("/window", body)
            frame = reply.get("frame") or {}
            return finish(reply, f"{frame.get('width')}x{frame.get('height')} at {frame.get('x')},{frame.get('y')}")
        if cmd == "tabs":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            reply = request("/tabs", {}, None)
            rows = []
            for row in reply.get("tabs", []):
                mark = "*" if row.get("active") else " "
                rows.append(f"{mark} {row.get('index')}  {row.get('id', '')}  window {str(row.get('window', ''))[:8]}  {len(row.get('panes') or [])} panes  {row.get('title', '')}")
            return finish(reply, "\n".join(rows))
        if cmd.startswith("tab-"):
            if not positional:
                raise Usage(f"give a tab id or index, like `aether {cmd} 1`. `aether tabs` lists them.")
            body = {"tab": positional.pop(0)}
            if cmd == "tab-rename":
                body["name"] = " ".join(positional)
                positional = []
            if cmd == "tab-move":
                if "--index" not in opts:
                    raise Usage("pass --index N.")
                body["index"] = int(number(opts["--index"], "--index"))
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            return finish(call("/" + cmd, body))
        if cmd == "set":
            if len(positional) == 1 or len(positional) > 2:
                raise Usage("give a key and a value, like `aether set fontSize 15`, or nothing to list them.")
            body = {"key": positional[0], "value": positional[1]} if positional else {}
            reply = request("/set", body, None)
            if not positional:
                rows = [f"{key} = {value}" for key, value in sorted((reply.get("settings") or {}).items())]
                return finish(reply, "\n".join(rows))
            return finish(reply, f"{reply.get('key')} = {reply.get('value')}")
        if cmd == "imgcat":
            if len(positional) != 1:
                raise Usage("give one image file, like `aether imgcat chart.png`.")
            try:
                with open(os.path.expanduser(positional[0]), "rb") as handle:
                    data = handle.read()
            except OSError as error:
                raise Failure(f"could not read {positional[0]}: {error.strerror}.")
            width = f";width={int(number(opts['--width'], '--width'))}" if "--width" in opts else ""
            name = base64.b64encode(os.path.basename(positional[0]).encode()).decode()
            sys.stdout.write(f"\x1b]1337;File=name={name};size={len(data)};inline=1{width}:" + base64.b64encode(data).decode() + "\a\n")
            sys.stdout.flush()
            return 0
        if cmd == "skill":
            if positional:
                raise Usage(f"unexpected {positional[0]}.")
            install_skill(bool(opts.get("--project")))
            return 0
        if cmd == "workspace":
            body = {}
            if opts.get("--title"):
                body["title"] = opts["--title"]
            words = list(command) if command is not None else list(positional)
            if len(words) == 1:
                body["command"] = words[0]
            elif words:
                body["command"] = " ".join(quote(word) for word in words)
            reply = call("/workspace", body)
            return finish(reply, reply.get("tab") or reply.get("pane"))
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
    )
    exec python3 -c "$program" "$@"
    """#

    static let skill = #"""
    ---
    name: aether
    description: Control the Aether terminal from a shell. Open panes, type into them, run commands to completion, read output, and close panes you opened.
    ---
    
    You are in Aether when `AETHER_PANE` or `AETHER=1` is set. Use the `aether` command. Do not guess keystrokes for splits. Aether installs this skill and a session hook on launch.
    
    Every command acts on your own pane (`AETHER_PANE`) unless you pass `--pane <id>`. Pane ids may be positional (`aether read 50BBAE3B`) or given as `--pane`. Outside Aether, with one window open that window is used; with several, pass `--pane`, `--window`, or `--desk`. Commands never move keyboard focus unless you pass `--focus`. Add `--json` to any command for the raw reply.
    
    Agent loop: spawn with `tab` or `run`, watch with `wait` / `read`, interrupt with `send --keys ctrl+c`, rerun with `run` or `send`.
    
    - `aether split --right --ratio 30 -- npm run dev` opens a terminal beside you and prints its id. Sides: `--right`, `--left`, `--up`, `--down`.
    - `aether tab -- command` adds a terminal to this tab group and prints its id.
    - `aether workspace --title school` opens a new tab group in the window. Terminals in other groups keep running.
    - `aether run -- make test` runs a command in a new pane, streams output, exits with that command's status, and closes the pane (`--keep` leaves it). `aether run --pane <id> -- npm test` types into an existing pane and waits until the shell is idle.
    - `aether send --keys ctrl+c` types into a pane. `aether send y --enter` answers a prompt. `--keys` accepts `ctrl+c`, `enter`, `up`, `tab`, `esc`, and comma-separated chords.
    - `aether wait <id> --exit` blocks until that pane's job exits. `--until-idle` waits for a prompt.
    - `aether open localhost:3000 --right --ratio 40` shows a page beside you.
    - `aether read` prints your screen. `aether read 50BBAE3B --lines 200` prints scrollback from another pane.
    - `aether view` lists panes (`*` focused, `<` you). `aether view --json` includes `command`, `window`, `desk`, `focused`.
    - `aether windows` lists windows. `aether find --command nmap` finds panes by title or running command.
    - `aether move <id> --before <id>` / `aether order <id> <id> ...` reorder panes in a window.
    - `aether status working "Running tests"` shows a dot on the header. States: `working`, `blocked`, `done`, `error`, `idle`.
    - `aether notify "Build finished"` posts a macOS notification.
    - `aether title "API server"` names a pane.
    - `aether close <id>` closes a pane you opened.
    - `aether screenshot --out /tmp/pane.png` saves a PNG of a pane.
    - `aether zoom` fills the window with your pane, or puts it back.
    - `aether resize <id> --grow right --by 10` / `--shrink down` moves one edge of a pane. `aether layout tall|fat|grid|columns|rows|stack|next` arranges a window; `aether equalize` evens it out.
    - `aether window --size 1400x900 --position 0,40` resizes and moves a window (points from the top-left of the main screen). `--zoom`, `--fullscreen`, and `--front` toggle. `aether windows --json` shows each frame.
    - `aether focus <id>` moves the keyboard into a pane and brings its window forward.
    - `aether tabs` lists tab groups. `aether tab-select 1`, `aether tab-rename 1 school`, `aether tab-move 1 --index 0`, `aether tab-close 1` take an index (from 0) or a tab id.
    - `aether set` lists settings agents may change; `aether set themeName Dracula`, `aether set fontSize 15`, `aether set glass clear`.
    - `aether imgcat chart.png` draws an image inline in your pane (iTerm2 protocol). Aether also draws kitty graphics and sixel, so `kitty +kitten icat` and `img2sixel` work too. `aether open file.pdf` shows a PDF beside you.
    - `aether font 1` or `aether font -1` changes the type size. `aether font 0` resets it.
    - `aether skill` installs this skill and AGENTS.md.
    - `aether mcp` speaks MCP on stdin/stdout (one tool per command).
    - `aether help <command>` shows options and examples.
    
    Exit codes: 0 worked, 1 Aether refused or is not running (the reason is on stderr), 2 bad arguments. `aether run` exits with the command's own status.
    
    "Beside you" means split your own pane. Leave focus alone unless asked. Close only panes you opened, and close them when you are done with them.
    """#

    static let agents = #"""
    # Aether
    
    Use the `aether` CLI to drive this macOS terminal. Prefer it over guessing tmux/iTerm keystrokes.
    
    ## Targeting
    
    - Inside Aether, `$AETHER_PANE` is your pane. Commands act there unless you pass `--pane <id>`.
    - Pane ids may be positional (`aether read 50BBAE3B`) or `--pane`. Unique 8-character prefixes work.
    - Outside Aether, with one window, that window is used. With several, pass `--pane`, `--window <id|this|any>`, or `--desk`.
    - `aether windows` and `aether view --json` are how you discover ids. `--json` works on every command. View JSON includes `tab` for the workspace group.
    
    ## Agent loop
    
    Keep a shell pane if you need to interrupt and rerun. A tab that is launched with a command (`aether tab -- ping`) exits when that command does.
    
    ```sh
    id=$(aether tab --title job)
    aether send "$id" 'ping -c 20 1.1.1.1' --enter
    aether send "$id" --keys ctrl+c
    aether wait "$id" --until-idle --timeout 30
    aether read "$id" --lines 50
    aether run --pane "$id" -- echo done
    aether close "$id"
    ```
    
    `aether run -- make test` is the one-shot form: new pane, stream output, exit with the command's status, close the pane (`--keep` leaves it). Ctrl-C on `aether run` sends ctrl+c into the pane. `--pane` is required to type into an existing pane; `$AETHER_PANE` is not enough.
    
    ## Commands
    
    | Command | Role |
    | --- | --- |
    | `tab` / `split` | Open a visible pane in this tab group. Prints the id. |
    | `workspace` | New tab group in the window. Other groups keep running. |
    | `run` | Run to completion; stream output; exit with the command's status. |
    | `send` | Type text or `--keys ctrl+c` / `enter`. |
    | `wait` | `--until-idle` or `--exit`. |
    | `read` | Screen and scrollback. |
    | `view` / `windows` / `find` | Discover panes. |
    | `title` / `status` / `notify` | Label and signal. |
    | `move` / `order` | Reorder panes in a window. |
    | `resize` / `layout` / `equalize` | Size panes and arrange a window. |
    | `window` | Size, move, zoom, or full-screen a window. |
    | `focus` | Move the keyboard into a pane. |
    | `tabs` / `tab-select` / `tab-rename` / `tab-move` / `tab-close` | Tab groups. |
    | `set` | Theme, glass, font size, and other safe settings. |
    | `imgcat` | Draw an image inline (kitty graphics and sixel work too). |
    | `close` | Close a pane you opened. |
    | `screenshot` | PNG of a pane. |
    | `mcp` | MCP stdio, one tool per command. |
    
    `aether help <command>` has flags and examples.
    
    Exit codes: 0 ok, 1 Aether refused or is not running, 2 bad arguments.
    """#
}
