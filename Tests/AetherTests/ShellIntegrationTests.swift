import AppKit
import Foundation
import Testing
@testable import AetherKit

private let root = URL(fileURLWithPath: "/tmp/Aether Support/shell-integration")

private func value(_ key: String, _ env: [String]) -> String? {
    env.last { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
}

@Test func zshGetsAetherZdotdirAndKeepsTheUsersOne() {
    let launch = ShellIntegration.plan(shell: "/bin/zsh", environment: ["HOME=/Users/a", "ZDOTDIR=/Users/a/.config/zsh"], root: root, enabled: true)
    #expect(launch.shell == .zsh)
    #expect(launch.args == ["-l"])
    #expect(value("ZDOTDIR", launch.environment) == "/tmp/Aether Support/shell-integration/zsh")
    #expect(value("AETHER_ORIG_ZDOTDIR", launch.environment) == "/Users/a/.config/zsh")
    #expect(launch.environment.filter { $0.hasPrefix("ZDOTDIR=") }.count == 1)
}

@Test func zshWithoutZdotdirLeavesNothingToRestore() {
    for env in [["HOME=/Users/a"], ["HOME=/Users/a", "ZDOTDIR="]] {
        let launch = ShellIntegration.plan(shell: "/opt/homebrew/bin/zsh", environment: env, root: root, enabled: true)
        #expect(value("AETHER_ORIG_ZDOTDIR", launch.environment) == nil)
        #expect(value("ZDOTDIR", launch.environment)?.hasSuffix("/zsh") == true)
    }
}

@Test func zshStartedFromAnAetherZdotdirDoesNotLoopBack() {
    let ours = root.appendingPathComponent("zsh").path
    let launch = ShellIntegration.plan(shell: "/bin/zsh", environment: ["ZDOTDIR=\(ours)"], root: root, enabled: true)
    #expect(value("AETHER_ORIG_ZDOTDIR", launch.environment) == nil)
    #expect(value("ZDOTDIR", launch.environment) == ours)
}

@Test func bashRunsTheRcfileAsAnInteractiveShell() {
    let launch = ShellIntegration.plan(shell: "/bin/bash", environment: ["HOME=/Users/a"], root: root, enabled: true)
    #expect(launch.args == ["--rcfile", "/tmp/Aether Support/shell-integration/bash/aether.bash", "-i"])
    #expect(value("AETHER_BASH_LOGIN", launch.environment) == "1")
}

@Test func fishFindsTheSnippetThroughXdgDataDirs() {
    let fresh = ShellIntegration.plan(shell: "/opt/homebrew/bin/fish", environment: [], root: root, enabled: true)
    #expect(value("XDG_DATA_DIRS", fresh.environment) == "/tmp/Aether Support/shell-integration/xdg:/usr/local/share:/usr/share")
    #expect(value("AETHER_ORIG_XDG_DATA_DIRS", fresh.environment) == nil)
    let kept = ShellIntegration.plan(shell: "/opt/homebrew/bin/fish", environment: ["XDG_DATA_DIRS=/nix/share"], root: root, enabled: true)
    #expect(value("XDG_DATA_DIRS", kept.environment) == "/tmp/Aether Support/shell-integration/xdg:/nix/share")
    #expect(value("AETHER_ORIG_XDG_DATA_DIRS", kept.environment) == "/nix/share")
}

@Test func otherShellsAndTheOffSwitchStartPlain() {
    let env = ["HOME=/Users/a", "ZDOTDIR=/z"]
    for launch in [
        ShellIntegration.plan(shell: "/usr/local/bin/nu", environment: env, root: root, enabled: true),
        ShellIntegration.plan(shell: "/bin/zsh", environment: env, root: root, enabled: false),
    ] {
        #expect(launch.shell == nil)
        #expect(launch.args == ["-l"])
        #expect(launch.environment == env)
    }
}

@Test func integrationTurnsOffFromSettingsOrEnvironment() {
    #expect(ShellIntegration.enabled(setting: true, environment: [:]))
    #expect(!ShellIntegration.enabled(setting: false, environment: [:]))
    #expect(!ShellIntegration.enabled(setting: true, environment: ["AETHER_SHELL_INTEGRATION": "0"]))
    #expect(!ShellIntegration.enabled(setting: true, environment: ["AETHER_SHELL_INTEGRATION": "off"]))
    #expect(ShellIntegration.enabled(setting: true, environment: ["AETHER_SHELL_INTEGRATION": "1"]))
}

@Test func settingDecodesAndDefaultsOn() throws {
    let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"shellIntegration": false}"#.utf8))
    #expect(!off.shellIntegration)
    let missing = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(missing.shellIntegration)
    let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off))
    #expect(!again.shellIntegration)
}

@Test func reportsDecode() {
    #expect(ShellEvent.parse("prompt;shell=zsh") == .prompt(shell: "zsh", exit: nil))
    #expect(ShellEvent.parse("prompt;shell=bash;exit=101") == .prompt(shell: "bash", exit: 101))
    #expect(ShellEvent.parse("prompt") == .prompt(shell: nil, exit: nil))
    #expect(ShellEvent.parse("cmd=cargo%20build%20--release") == .command("cargo build --release"))
    #expect(ShellEvent.parse("cmd=echo%20a%3B%20echo%20%22%C3%A9%E2%80%94%22") == .command("echo a; echo \"é—\""))
    #expect(ShellEvent.parse("cmd=a;b") == .command("a;b"))
    #expect(ShellEvent.parse("cmd=100%") == .command("100%"))
    #expect(ShellEvent.parse("cmd=%E2%80") == .command("\u{FFFD}"))
    #expect(ShellEvent.parse("cmd=") == nil)
    #expect(ShellEvent.parse("hello") == nil)
}

@Test func trackerTimesCommandsAndKeepsTheirStatus() {
    var tracker = CommandTracker()
    let start = Date(timeIntervalSince1970: 1000)
    #expect(!tracker.active)
    #expect(tracker.apply(.prompt(shell: "zsh", exit: nil), at: start) == nil)
    #expect(tracker.active)
    #expect(tracker.shell == "zsh")
    #expect(tracker.apply(.command("cargo build"), at: start) == nil)
    #expect(tracker.running?.line == "cargo build")
    let done = tracker.apply(.prompt(shell: "zsh", exit: 101), at: start.addingTimeInterval(48))
    #expect(done == FinishedCommand(line: "cargo build", started: start, elapsed: 48, exitCode: 101))
    #expect(tracker.running == nil)
    // An empty Enter is a prompt with nothing running.
    #expect(tracker.apply(.prompt(shell: "zsh", exit: nil), at: start.addingTimeInterval(50)) == nil)
}

@Test func execHandsTheTerminalToSomethingElse() {
    var tracker = CommandTracker()
    _ = tracker.apply(.prompt(shell: "zsh", exit: nil), at: Date())
    #expect(tracker.apply(.command("exec zsh"), at: Date()) == nil)
    #expect(!tracker.active)
    #expect(tracker.running == nil)
}

@Test func promptNavigationPicksTheNearestPrompt() {
    let prompts = [3, 10, 25, 40]
    #expect(PromptNavigator.target(prompts: prompts, from: 30, .previous) == 25)
    #expect(PromptNavigator.target(prompts: prompts, from: 25, .previous) == 10)
    #expect(PromptNavigator.target(prompts: prompts, from: 3, .previous) == nil)
    #expect(PromptNavigator.target(prompts: prompts, from: 10, .next) == 25)
    #expect(PromptNavigator.target(prompts: prompts, from: 40, .next) == nil)
    #expect(PromptNavigator.target(prompts: [], from: 5, .previous) == nil)
}

@Test func outputSpanRunsFromFirstToLastPrintedCell() {
    #expect(PromptNavigator.outputSpan([]) == nil)
    let span = PromptNavigator.outputSpan([(row: 11, first: 0, last: 30), (row: 12, first: 2, last: 7)])
    #expect(span?.start.row == 11)
    #expect(span?.start.col == 0)
    #expect(span?.end.row == 12)
    #expect(span?.end.col == 7)
}

@Test func notificationTextUsesTheCommandAndItsStatus() {
    let ok = ShellIntegration.notification(for: FinishedCommand(line: "cargo build", started: Date(), elapsed: 48, exitCode: 0))
    #expect(ok.title == "cargo build")
    #expect(ok.body == "✓ cargo build · 48s")
    let failed = ShellIntegration.notification(for: FinishedCommand(line: "cargo build", started: Date(), elapsed: 3, exitCode: 101))
    #expect(failed.body == "✗ cargo build failed (exit 101)")
    let long = ShellIntegration.notification(for: FinishedCommand(line: "make  \n  " + String(repeating: "x", count: 80), started: Date(), elapsed: 75, exitCode: 0))
    #expect(long.title.count == 60)
    #expect(long.title.hasPrefix("make xxx"))
    #expect(long.title.hasSuffix("…"))
}

@Test func promptKeysDoNotCollideWithOtherShortcuts() {
    let map = KeyMap.standard
    let chords = AppAction.allCases.map { map.chord($0) }.filter { !$0.key.isEmpty }
    for action in [AppAction.previousPrompt, .nextPrompt, .selectLastOutput] {
        let chord = map.chord(action)
        #expect(chords.filter { $0.key == chord.key && $0.modifiers == chord.modifiers }.count == 1)
    }
    #expect(AppAction.previousPrompt.defaultChord.symbol == "⌘↑")
    #expect(AppAction.nextPrompt.defaultChord.symbol == "⌘↓")
    #expect(AppAction.selectLastOutput.defaultChord.symbol == "⇧⌘A")
}

@Test func savedKeyMapsPickUpThePromptKeys() throws {
    var old = KeyMap.standard
    for action in [AppAction.previousPrompt, .nextPrompt, .selectLastOutput] {
        old.chords[action.rawValue] = nil
    }
    let decoded = try JSONDecoder().decode(KeyMap.self, from: JSONEncoder().encode(old)).filled()
    #expect(decoded.chord(.previousPrompt) == AppAction.previousPrompt.defaultChord)
}

@Test func installWritesEachScriptOnce() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-si-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(ShellIntegration.install(at: dir))
    let zshenv = dir.appendingPathComponent("zsh/.zshenv")
    #expect(FileManager.default.fileExists(atPath: zshenv.path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("zsh/aether-integration").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bash/aether.bash").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("xdg/fish/vendor_conf.d/aether.fish").path))
    let before = try FileManager.default.attributesOfItem(atPath: zshenv.path)[.modificationDate] as? Date
    Thread.sleep(forTimeInterval: 0.05)
    #expect(ShellIntegration.install(at: dir))
    let after = try FileManager.default.attributesOfItem(atPath: zshenv.path)[.modificationDate] as? Date
    #expect(before == after)
}

/// Starts real zsh and bash under script(1) with a throwaway HOME. It takes about 20 seconds, so it runs
/// with `AETHER_SHELL_TESTS=1 swift test --filter shellIntegrationEndToEnd`. See scripts/test-shell-integration.sh.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AETHER_SHELL_TESTS"] == "1"))
func shellIntegrationEndToEnd() throws {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/test-shell-integration.sh")
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script"),
          FileManager.default.isExecutableFile(atPath: script.path) else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-si-e2e-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(ShellIntegration.install(at: dir))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, dir.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(output)")
}
