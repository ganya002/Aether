import Foundation

/// Installs the Aether skill and a session hook into every agent home Aether can find,
/// so a new Claude, Codex, Cursor, Gemini, or OpenCode session already knows it can
/// drive this terminal. Never writes into the current git repo.
enum AgentSkills {
    static let marker = "aether hook"
    static let managed = "aether-managed"

    struct Target: Equatable {
        var name: String
        var root: URL
        var skillDir: URL
        var hookFile: URL?
        var hookKind: HookKind?
        var rulesFile: URL?
    }

    enum HookKind: Equatable {
        case claudeSettings
        case codexHooks
    }

    static func targets(home: URL, env: [String: String], path: String) -> [Target] {
        func dir(_ key: String, _ fallback: String) -> URL {
            if let value = env[key], !value.isEmpty {
                return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            }
            return home.appendingPathComponent(fallback)
        }
        let bins = path.split(separator: ":").map(String.init)
        func hasBinary(_ names: String...) -> Bool {
            names.contains { name in
                bins.contains { FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(name)) }
            }
        }
        var list: [Target] = []
        let claude = dir("CLAUDE_CONFIG_DIR", ".claude")
        if FileManager.default.fileExists(atPath: claude.path) || hasBinary("claude") {
            list.append(Target(
                name: "Claude Code",
                root: claude,
                skillDir: claude.appendingPathComponent("skills/aether"),
                hookFile: claude.appendingPathComponent("settings.json"),
                hookKind: .claudeSettings,
                rulesFile: nil
            ))
        }
        let cursor = dir("CURSOR_CONFIG_DIR", ".cursor")
        if FileManager.default.fileExists(atPath: cursor.path) || hasBinary("cursor", "cursor-agent") {
            list.append(Target(
                name: "Cursor",
                root: cursor,
                skillDir: cursor.appendingPathComponent("skills/aether"),
                hookFile: nil,
                hookKind: nil,
                rulesFile: cursor.appendingPathComponent("rules/aether.mdc")
            ))
        }
        let agents = dir("AGENTS_HOME", ".agents")
        let codex = dir("CODEX_HOME", ".codex")
        let opencode = dir("OPENCODE_CONFIG_DIR", ".opencode")
        let gemini = dir("GEMINI_CONFIG_DIR", ".gemini")
        if FileManager.default.fileExists(atPath: agents.path) || hasBinary("pi") {
            list.append(Target(
                name: "Pi",
                root: agents,
                skillDir: agents.appendingPathComponent("skills/aether"),
                hookFile: nil,
                hookKind: nil,
                rulesFile: nil
            ))
        }
        if FileManager.default.fileExists(atPath: codex.path) || hasBinary("codex") {
            list.append(Target(
                name: "Codex",
                root: codex,
                skillDir: codex.appendingPathComponent("skills/aether"),
                hookFile: codex.appendingPathComponent("hooks.json"),
                hookKind: .codexHooks,
                rulesFile: nil
            ))
        }
        if FileManager.default.fileExists(atPath: opencode.path) || hasBinary("opencode") {
            list.append(Target(
                name: "OpenCode",
                root: opencode,
                skillDir: opencode.appendingPathComponent("skills/aether"),
                hookFile: nil,
                hookKind: nil,
                rulesFile: nil
            ))
        }
        if FileManager.default.fileExists(atPath: gemini.path) || hasBinary("gemini") {
            list.append(Target(
                name: "Gemini CLI",
                root: gemini,
                skillDir: gemini.appendingPathComponent("skills/aether"),
                hookFile: nil,
                hookKind: nil,
                rulesFile: gemini.appendingPathComponent("GEMINI.md")
            ))
        }
        return list
    }

    static func hookCommand(binary: URL) -> String {
        "\"\(binary.path)\" hook # \(marker)"
    }

    static func mergeClaudeSettings(_ json: Data, command: String) -> Data {
        var root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var session = hooks["SessionStart"] as? [[String: Any]] ?? []
        session = session.filter { group in
            let inner = group["hooks"] as? [[String: Any]] ?? []
            return !inner.contains { ($0["command"] as? String)?.contains(marker) == true }
                && !((group["command"] as? String)?.contains(marker) == true)
        }
        session.append([
            "hooks": [[
                "type": "command",
                "command": command,
            ]],
        ])
        hooks["SessionStart"] = session
        root["hooks"] = hooks
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? json
    }

    static func mergeCodexHooks(_ json: Data, command: String) -> Data {
        var root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        if var hooks = root["hooks"] as? [String: Any] {
            var session = hooks["SessionStart"] as? [[String: Any]] ?? []
            session = session.filter { !(($0["command"] as? String)?.contains(marker) == true) }
            session.append(["type": "command", "command": command])
            hooks["SessionStart"] = session
            root["hooks"] = hooks
        } else {
            var session = root["SessionStart"] as? [[String: Any]] ?? []
            session = session.filter { !(($0["command"] as? String)?.contains(marker) == true) }
            session.append(["type": "command", "command": command])
            if root["hooks"] == nil, root["SessionStart"] != nil {
                root["SessionStart"] = session
            } else {
                root["hooks"] = ["SessionStart": session]
            }
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? json
    }

    static func cursorRule() -> String {
        """
        ---
        description: Drive the Aether terminal with the aether CLI
        alwaysApply: true
        ---

        <!-- \(managed) -->
        If `$AETHER_PANE` or `$AETHER` is set, you are inside Aether. Use the `aether` CLI (already on PATH) to split, open workspace tabs, send keys, run commands, and read screens. `aether workspace` is a new tab group; `aether tab` is a new pane in this group. Do not guess tmux or iTerm keystrokes. Run `aether help` or `aether hook` for the current pane.
        """
    }

    static func geminiNote() -> String {
        """
        <!-- \(managed) -->
        If `$AETHER_PANE` or `$AETHER` is set, you are inside Aether. Use the `aether` CLI to control this terminal. `aether workspace` opens a tab group. Run `aether help`.
        """
    }

    @discardableResult
    static func install(
        skill: String,
        agents: String,
        binary: URL,
        home: URL,
        env: [String: String],
        path: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let command = hookCommand(binary: binary)
        var done: [String] = []
        for target in targets(home: home, env: env, path: path) {
            do {
                try fileManager.createDirectory(at: target.skillDir, withIntermediateDirectories: true)
                try skill.write(to: target.skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                try agents.write(to: target.skillDir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
                if let hookFile = target.hookFile, let kind = target.hookKind {
                    try fileManager.createDirectory(at: hookFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let existing = (try? Data(contentsOf: hookFile)) ?? Data("{}".utf8)
                    let merged = kind == .claudeSettings ? mergeClaudeSettings(existing, command: command) : mergeCodexHooks(existing, command: command)
                    try merged.write(to: hookFile, options: .atomic)
                }
                if let rules = target.rulesFile {
                    try fileManager.createDirectory(at: rules.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let text = target.name == "Gemini CLI" ? geminiNote() : cursorRule()
                    if fileManager.fileExists(atPath: rules.path) {
                        let current = (try? String(contentsOf: rules, encoding: .utf8)) ?? ""
                        if current.contains(managed) {
                            try text.write(to: rules, atomically: true, encoding: .utf8)
                        }
                    } else {
                        try text.write(to: rules, atomically: true, encoding: .utf8)
                    }
                }
                done.append(target.name)
            } catch {
                continue
            }
        }
        return done
    }
}
