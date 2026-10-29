import Foundation
import Network
import Testing
@testable import AetherKit

private func request(_ body: String, headers: [String] = ["Authorization: TOKEN"], path: String = "/split") -> Data {
    let lines = ["POST \(path) HTTP/1.1", "Host: 127.0.0.1"] + headers + ["Content-Length: \(Data(body.utf8).count)"]
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
}

private func desk(_ id: String, _ panes: [String], focused: String) -> Desk {
    var states: [String: PaneState] = [:]
    for pane in panes {
        states[pane] = PaneState(id: pane, cwd: "/tmp", command: nil, title: pane, exitCode: nil)
    }
    return Desk(id: id, layout: Layout.arrange(panes, pattern: .rows) ?? .pane(panes[0]), kind: .tall, focusedID: focused, maximizedID: nil, broadcast: false, frame: .zero, panes: states)
}

@Suite struct AgentHTTPTests {
    @Test func parsesACompleteRequest() {
        guard case .complete(let parsed) = AgentHTTP.parse(request(#"{"pane":"A"}"#)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.route == "/split")
        #expect(parsed.headers["authorization"] == "TOKEN")
        #expect(AgentHTTP.json(parsed.body)?["pane"] as? String == "A")
    }

    @Test func waitsForEveryByteWhenTCPSplitsTheRequest() {
        let whole = request(#"{"direction":"left","command":"npm run dev"}"#)
        for cut in 1..<whole.count {
            #expect(AgentHTTP.parse(whole.prefix(cut)) == .incomplete, "cut at \(cut)")
        }
        guard case .complete(let parsed) = AgentHTTP.parse(whole) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(AgentHTTP.json(parsed.body)?["direction"] as? String == "left")
    }

    @Test func readsExactlyContentLengthBytes() {
        var data = request("{}")
        data.append(Data("garbage".utf8))
        guard case .complete(let parsed) = AgentHTTP.parse(data) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(parsed.body == Data("{}".utf8))
    }

    @Test func noContentLengthMeansNoBody() {
        let data = Data("GET /view HTTP/1.1\r\nAuthorization: T\r\n\r\n".utf8)
        guard case .complete(let parsed) = AgentHTTP.parse(data) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(parsed.body.isEmpty)
        #expect(AgentHTTP.json(parsed.body)?.isEmpty == true)
    }

    @Test func rejectsOversizedAndMalformedRequests() {
        #expect(AgentHTTP.parse(request("{}", headers: ["Content-Length: 2000000"])) == .invalid(400, "Conflicting content-length headers."))
        let huge = Data("POST /split HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n".utf8)
        #expect(AgentHTTP.parse(huge) == .invalid(413, "The request is too large."))
        #expect(AgentHTTP.parse(Data(repeating: 65, count: 64), limit: 32) == .invalid(413, "The request is too large."))
        #expect(AgentHTTP.parse(Data("POST /split HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)) == .invalid(400, "Bad Content-Length."))
        #expect(AgentHTTP.parse(Data("POST /split HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .invalid(400, "Bad Content-Length."))
        #expect(AgentHTTP.parse(Data("POST /split HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid(411, "Send a Content-Length."))
        #expect(AgentHTTP.parse(Data("hello\r\n\r\n".utf8)) == .invalid(400, "Bad request line."))
        #expect(AgentHTTP.parse(Data("POST /split HTTP/1.1\r\nno colon\r\n\r\n".utf8)) == .invalid(400, "Bad header."))
    }

    @Test func stripsTheQueryFromTheRoute() {
        guard case .complete(let parsed) = AgentHTTP.parse(request("", path: "/read?x=1")) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(parsed.route == "/read")
    }

    @Test func authorizationMustMatchTheTokenExactly() {
        let token = "5C1D2E3F-AAAA-BBBB-CCCC-0123456789AB"
        #expect(AgentHTTP.authorized(token, token: token))
        #expect(AgentHTTP.authorized("Bearer \(token)", token: token))
        #expect(!AgentHTTP.authorized(nil, token: token))
        #expect(!AgentHTTP.authorized("", token: token))
        #expect(!AgentHTTP.authorized("x\(token)", token: token))
        #expect(!AgentHTTP.authorized("\(token)x", token: token))
        #expect(!AgentHTTP.authorized(String(token.dropLast()), token: token))
        #expect(!AgentHTTP.authorized(token.lowercased(), token: token))
        #expect(!AgentHTTP.authorized("", token: ""))
    }

    @Test func aTokenInTheBodyDoesNotAuthorize() {
        let token = "SECRET"
        guard case .complete(let parsed) = AgentHTTP.parse(request(#"{"x":"SECRET"}"#, headers: ["Authorization: wrong", "X-Note: SECRET"])) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(!AgentHTTP.authorized(parsed.headers["authorization"], token: token))
    }

    @Test func repliesWithRealStatusLines() {
        let text = String(decoding: AgentHTTP.response(404, ["ok": false]), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(String(decoding: AgentHTTP.response(401, [:]), as: UTF8.self).hasPrefix("HTTP/1.1 401 Unauthorized"))
    }

    @Test func rejectsBodiesThatAreNotObjects() {
        #expect(AgentHTTP.json(Data("[1]".utf8)) == nil)
        #expect(AgentHTTP.json(Data("{".utf8)) == nil)
        #expect(AgentHTTP.json(Data("  \n".utf8))?.isEmpty == true)
    }
}

@Suite struct AgentArgsTests {
    @Test func centerSplitsToTheRightInsteadOfHidingAPane() {
        #expect(AgentArgs.zone("center") == .right)
        #expect(AgentArgs.zone(nil) == .right)
        #expect(AgentArgs.zone("up") == .top)
        #expect(AgentArgs.zone("down") == .bottom)
        #expect(AgentArgs.zone("Left") == .left)
        #expect(AgentArgs.zone("diagonal") == nil)
        #expect(AgentArgs.zone(5) == nil)
    }

    @Test func targetsTheCallingPaneNotTheFocusedOne() {
        let desks = ["D1": desk("D1", ["A", "B"], focused: "A"), "D2": desk("D2", ["C"], focused: "C")]
        let target = try? AgentArgs.target(pane: "B", session: nil, desks: desks, sessions: [:], keyDesk: "D2").get()
        #expect(target == AgentArgs.Target(desk: "D1", pane: "B", explicit: true))
    }

    @Test func fallsBackToTheFocusedPaneOnlyWithoutAPane() {
        let desks = ["D1": desk("D1", ["A", "B"], focused: "A"), "D2": desk("D2", ["C"], focused: "C")]
        let target = try? AgentArgs.target(pane: nil, session: nil, desks: desks, sessions: [:], keyDesk: "D1").get()
        #expect(target == AgentArgs.Target(desk: "D1", pane: "A", explicit: false))
        let empty = try? AgentArgs.target(pane: "", session: "", desks: desks, sessions: [:], keyDesk: "D2").get()
        #expect(empty == AgentArgs.Target(desk: "D2", pane: "C", explicit: false))
    }

    @Test func anUnknownPaneIsAnErrorNotTheFocusedPane() {
        let desks = ["D1": desk("D1", ["A"], focused: "A")]
        let result = AgentArgs.target(pane: "gone", session: nil, desks: desks, sessions: [:], keyDesk: "D1")
        #expect(result == .failure(AgentError("No pane gone.")))
        #expect(AgentArgs.target(pane: nil, session: nil, desks: [:], sessions: [:], keyDesk: nil) == .failure(AgentError("No Aether window is open.")))
    }

    @Test func aCloudSessionFindsItsPane() {
        let desks = ["D1": desk("D1", ["A", "B"], focused: "A")]
        let target = try? AgentArgs.target(pane: nil, session: "S1", desks: desks, sessions: ["B": "S1"], keyDesk: "D1").get()
        #expect(target == AgentArgs.Target(desk: "D1", pane: "B", explicit: true))
    }

    @Test func aCloudRequestOnlyReachesItsOwnPane() {
        let desks = ["D1": desk("D1", ["A", "B"], focused: "A")]
        let own = try? AgentArgs.target(pane: nil, session: "S1", desks: desks, sessions: ["B": "S1"], keyDesk: "D1", allowFocusedFallback: false).get()
        #expect(own == AgentArgs.Target(desk: "D1", pane: "B", explicit: true))
        let missing = AgentError(AgentArgs.cloudTerminalMissing)
        #expect(AgentArgs.target(pane: nil, session: "S9", desks: desks, sessions: ["B": "S1"], keyDesk: "D1", allowFocusedFallback: false) == .failure(missing))
        #expect(AgentArgs.target(pane: nil, session: nil, desks: desks, sessions: [:], keyDesk: "D1", allowFocusedFallback: false) == .failure(missing))
        #expect(AgentArgs.target(pane: "A", session: "S9", desks: desks, sessions: ["B": "S1"], keyDesk: "D1", allowFocusedFallback: false) == .failure(missing))
    }

    @Test func tailKeepsTheLastLinesWithoutTrailingBlanks() {
        #expect(AgentArgs.tail("a\nb\nc\n\n  \n", lines: 2) == "b\nc")
        #expect(AgentArgs.tail("a\nb", lines: 10) == "a\nb")
    }
}

@Suite struct AgentCLITests {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func embeddedCLIMatchesScriptsAether() throws {
        #expect(AgentCLI.source + "\n" == (try repoFile("scripts/aether")))
    }

    @Test func embeddedSkillMatchesSkillFile() throws {
        #expect(AgentCLI.skill + "\n" == (try repoFile("scripts/aether-skill/SKILL.md")))
    }

    @Test func embeddedAgentsMatchesAgentsFile() throws {
        #expect(AgentCLI.agents + "\n" == (try repoFile("scripts/aether-skill/AGENTS.md")))
    }

    @MainActor @Test func sendAndRunShowUpInHelp() throws {
        #expect(AgentCLI.source.contains("aether send"))
        #expect(AgentCLI.source.contains("aether run"))
        #expect(AgentCLI.source.contains("aether wait"))
        #expect(AgentCLI.source.contains("--until-idle"))
        #expect(AgentDesk.routes.contains("/send"))
        #expect(AgentDesk.routes.contains("/wait"))
        #expect(AgentDesk.routes.contains("/windows"))
        #expect(AgentDesk.routes.contains("/workspace"))
        #expect(AgentCLI.source.contains("aether workspace"))
        #expect(AgentCLI.source.contains("aether hook"))
    }

    @Test func readTakesAPositionalPaneId() throws {
        let text = try runCLI(["read", "50BBAE3B-AAAA-BBBB-CCCC-0123456789AB"])
        #expect(!text.err.contains("unexpected"), "CLI still rejected a positional pane id: \(text.err)")
        #expect(text.status == 1)
        #expect(text.err.contains("Aether is not running") || text.err.contains("control port"))
    }

    @Test func sendTakesAPositionalPaneIdWithoutTreatingItAsText() throws {
        let text = try runCLI(["send", "50BBAE3B-AAAA-BBBB-CCCC-0123456789AB"])
        #expect(!text.err.contains("unexpected"), "CLI still rejected a positional pane id: \(text.err)")
        #expect(text.status == 2)
        #expect(text.err.contains("give text") || text.err.contains("--keys"))
    }

    @Test func hookPrintsWhenInsideAether() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/aether")
        process.arguments = ["hook"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["AETHER_PANE"] = "50BBAE3B-AAAA-BBBB-CCCC-0123456789AB"
        process.environment = env
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(text.contains("You are in Aether"))
        #expect(text.contains("aether workspace"))
    }

    @Test func hookIsSilentOutsideAether() throws {
        let text = try runCLI(["hook"])
        #expect(text.status == 0)
        #expect(text.err.isEmpty)
    }

    @Test func skillProjectIsAFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aether-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/aether")
        process.arguments = ["skill", "--project"]
        process.currentDirectoryURL = home
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["AETHER_AGENT_PLIST"] = home.appendingPathComponent("missing.plist").path
        env["AETHER_PANE"] = ""
        process.environment = env
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(!message.contains("needs a value"), "CLI treated --project as a value: \(message)")
        #expect(process.terminationStatus == 1)
        try? FileManager.default.removeItem(at: home)
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, err: String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/aether")
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["AETHER_AGENT_PLIST"] = "/tmp/aether-missing-agent.plist"
        env["AETHER_PANE"] = ""
        process.environment = env
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, message)
    }
}

@Suite struct AgentListenerTests {
    @Test func listensOnLoopbackOnly() {
        let parameters = AgentDesk.parameters(port: 17391)
        #expect(parameters.requiredInterfaceType == .loopback)
        guard case .hostPort(let host, let port) = parameters.requiredLocalEndpoint else {
            Issue.record("expected a host and port")
            return
        }
        #expect(host == .ipv4(.loopback))
        #expect(port.rawValue == 17391)
    }
}

@Suite struct AgentSkillsNoteTests {
    @Test func noteKeepsTheRestOfTheFile() {
        let mine = "# My rules\n\nBe brief.\n"
        let once = AgentSkills.withNote(mine)
        #expect(once.hasPrefix(mine))
        #expect(once.contains(AgentSkills.blockStart) && once.contains(AgentSkills.blockEnd))
        #expect(AgentSkills.withNote(once) == once)
        let edited = once + "\nMore of my own.\n"
        let updated = AgentSkills.withNote(edited, note: "\(AgentSkills.blockStart)\nnew\n\(AgentSkills.blockEnd)")
        #expect(updated == mine + "\n\(AgentSkills.blockStart)\nnew\n\(AgentSkills.blockEnd)\n\nMore of my own.\n")
    }

    @Test func noteReplacesTheOlderUnclosedBlock() {
        let old = "Mine.\n\n\(AgentSkills.blockStart)\nOld Aether paragraph.\n\nAlso mine.\n"
        let next = AgentSkills.withNote(old, note: "NOTE")
        #expect(next == "Mine.\n\nNOTE\n\nAlso mine.\n")
    }

    @Test func settingsThatAreNotJSONAreLeftAlone() {
        #expect(AgentSkills.mergeClaudeSettings(Data("{ // comment\n}".utf8), command: "x") == nil)
        #expect(AgentSkills.mergeClaudeSettings(Data("".utf8), command: "x") != nil)
    }

    @Test func codexHooksUseTheNestedShapeAndDropTheFlatOne() throws {
        let flat = #"{"hooks":{"SessionStart":[{"type":"command","command":"old # aether hook"},{"hooks":[{"type":"command","command":"orca"}]}]}}"#
        let merged = try #require(AgentSkills.mergeCodexHooks(Data(flat.utf8), command: AgentSkills.hookCommand()))
        let json = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        let session = ((json?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
        #expect(session.count == 2)
        #expect(session.allSatisfy { $0["hooks"] != nil })
    }

    @Test func installWritesTheBlockIntoCodexAndOpenCodeRules() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aether-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        try "Keep me.\n".write(to: home.appendingPathComponent(".codex/AGENTS.md"), atomically: true, encoding: .utf8)
        AgentSkills.install(skill: "s\n", agents: "a\n", home: home, env: [:], path: "/nonexistent")
        let codex = try String(contentsOf: home.appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)
        let opencode = try String(contentsOf: home.appendingPathComponent(".config/opencode/AGENTS.md"), encoding: .utf8)
        #expect(codex.hasPrefix("Keep me.\n") && codex.contains(AgentSkills.blockEnd))
        #expect(opencode.contains(AgentSkills.blockStart))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path))
    }
}

@Suite struct AgentMCPTests {
    /// MCP's stdio transport is newline-delimited JSON-RPC on stdin, so stdin must not hold the program.
    @Test func speaksMCPOverStdio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/aether")
        process.arguments = ["mcp"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["AETHER_AGENT_PLIST"] = "/tmp/aether-missing-agent.plist"
        env["AETHER_PANE"] = ""
        process.environment = env
        try process.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read","arguments":{"args":["50BBAE3B"]}}}"#,
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(replies.map { $0["id"] as? Int } == [1, 2, 3])
        let initialize = replies.first?["result"] as? [String: Any]
        #expect(initialize?["protocolVersion"] as? String == "2025-06-18")
        let tools = ((replies.dropFirst().first?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(tools.contains { $0["name"] as? String == "run" })
        let call = replies.last?["result"] as? [String: Any]
        #expect(call?["isError"] as? Bool == true)
        let text = ((call?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("Aether is not running"))
    }
}

@Suite struct AgentControlExtrasTests {
    @Test func resizeMovesTheEdgeItNames() {
        let tree = LayoutNode.split(id: "s", axis: .row, ratio: 0.5, a: .pane("left"), b: .pane("right"))
        #expect(Layout.ratio(of: "s", in: Layout.resize(tree, pane: "left", edge: .right, by: 0.1)) == 0.6)
        #expect(Layout.ratio(of: "s", in: Layout.resize(tree, pane: "right", edge: .left, by: 0.1)) == 0.4)
        #expect(Layout.ratio(of: "s", in: Layout.resize(tree, pane: "right", edge: .left, by: -0.1)) == 0.6)
        #expect(Layout.resize(tree, pane: "left", edge: .left, by: 0.1) == tree)
        #expect(Layout.resize(tree, pane: "left", edge: .down, by: 0.1) == tree)
    }

    @MainActor @Test func settingsAreTypedLikeTheValueTheyReplace() throws {
        let base = Settings()
        #expect(AppModel.setting(base, key: "fontSize", value: "15")?.fontSize == 15)
        #expect(AppModel.setting(base, key: "cursorBlink", value: "on")?.cursorBlink == true)
        #expect(AppModel.setting(base, key: "glass", value: "clear")?.glass == .clear)
        #expect(AppModel.setting(base, key: "glass", value: "bogus") == nil)
        #expect(AppModel.setting(base, key: "fontSize", value: "big") == nil)
        #expect(!AppModel.agentSettingKeys.contains("sessionToken"))
    }
}
