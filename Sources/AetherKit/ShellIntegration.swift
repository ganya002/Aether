import AppKit
import SwiftTerm

/// Prompt marks, the working directory, and each command's text and exit status, reported by the shell itself.
/// Aether loads small hooks into zsh, bash, and fish without touching anyone's dotfiles:
/// zsh gets a ZDOTDIR whose .zshenv hands back to the real one, bash an --rcfile that runs the usual
/// login files, and fish a vendor_conf.d snippet. Other shells start exactly as before.
///
/// The hooks send OSC 7 (directory), OSC 133 A/B/C/D (prompt, input, output, finished), OSC 2 (title),
/// and Aether's own OSC 7502: `prompt;shell=zsh;exit=0` at each prompt and `cmd=<percent-encoded line>`
/// before each command.
enum ShellIntegration {
    enum Shell: String, Equatable, Sendable {
        case zsh, bash, fish
    }

    struct Launch: Equatable, Sendable {
        var args: [String]
        var environment: [String]
        var shell: Shell?
    }

    static func shell(for path: String) -> Shell? {
        Shell(rawValue: URL(fileURLWithPath: path).lastPathComponent.lowercased())
    }

    /// Off when config.json says `"shellIntegration": false`, or Aether itself was started with AETHER_SHELL_INTEGRATION=0.
    static func enabled(setting: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard setting else { return false }
        let flag = environment["AETHER_SHELL_INTEGRATION"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return !["0", "false", "no", "off"].contains(flag)
    }

    /// How to start an interactive login shell, with the hooks when the shell is one Aether knows.
    static func plan(shell path: String, environment: [String], root: URL, enabled: Bool) -> Launch {
        let plain = Launch(args: ["-l"], environment: environment, shell: nil)
        guard enabled, let shell = shell(for: path) else { return plain }
        var env = environment
        switch shell {
        case .zsh:
            let ours = root.appendingPathComponent("zsh").path
            let original = value("ZDOTDIR", in: env)
            remove("ZDOTDIR", from: &env)
            remove("AETHER_ORIG_ZDOTDIR", from: &env)
            if let original, !original.isEmpty, original != ours {
                env.append("AETHER_ORIG_ZDOTDIR=\(original)")
            }
            env.append("ZDOTDIR=\(ours)")
            return Launch(args: ["-l"], environment: env, shell: .zsh)
        case .bash:
            env.append("AETHER_BASH_LOGIN=1")
            let rc = root.appendingPathComponent("bash/aether.bash").path
            return Launch(args: ["--rcfile", rc, "-i"], environment: env, shell: .bash)
        case .fish:
            let data = root.appendingPathComponent("xdg").path
            let original = value("XDG_DATA_DIRS", in: env)
            remove("XDG_DATA_DIRS", from: &env)
            remove("AETHER_ORIG_XDG_DATA_DIRS", from: &env)
            if let original, !original.isEmpty {
                env.append("AETHER_ORIG_XDG_DATA_DIRS=\(original)")
            }
            // Fish only falls back to its default data dirs while the variable is unset.
            env.append("XDG_DATA_DIRS=\(data):\(original.flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share")")
            env.append("AETHER_FISH_DATA_DIR=\(data)")
            return Launch(args: ["-l"], environment: env, shell: .fish)
        }
    }

    static func root() -> URL {
        System.supportDirectory().appendingPathComponent("shell-integration", isDirectory: true)
    }

    /// Writes the scripts, leaving files that already match alone.
    @discardableResult
    static func install(at root: URL = root()) -> Bool {
        var ok = true
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            let data = Data((text + "\n").utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                ok = false
            }
        }
        return ok
    }

    static let files: [(String, String)] = [
        ("zsh/.zshenv", zshEnv),
        ("zsh/aether-integration", zshIntegration),
        ("bash/aether.bash", bashIntegration),
        ("xdg/fish/vendor_conf.d/aether.fish", fishIntegration),
    ]

    private static func value(_ key: String, in env: [String]) -> String? {
        env.last { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    private static func remove(_ key: String, from env: inout [String]) {
        env.removeAll { $0.hasPrefix(key + "=") }
    }

    /// A command line short enough for a pane header or a notification title.
    static func summary(_ line: String, limit: Int = 40) -> String {
        let flat = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(1, limit - 1))) + "…"
    }

    /// Title and body for a finished command: "cargo build" and "✓ cargo build · 48s".
    static func notification(for finished: FinishedCommand) -> (title: String, body: String) {
        let title = summary(finished.line, limit: 60)
        return (title, FinishNotifier.phrase(command: summary(finished.line), elapsed: finished.elapsed, exitCode: finished.exitCode))
    }
}

// MARK: - Events

enum ShellEvent: Equatable, Sendable {
    /// The shell is showing a prompt. `exit` is the status of the command that just finished, if one ran.
    case prompt(shell: String?, exit: Int32?)
    case command(String)

    /// Reads the body of an OSC 7502 sequence.
    static func parse(_ body: String) -> ShellEvent? {
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = fields.first else { return nil }
        if first == "prompt" {
            var shell: String?
            var exit: Int32?
            for field in fields.dropFirst() {
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "shell": shell = String(pair[1])
                case "exit": exit = Int32(pair[1])
                default: break
                }
            }
            return .prompt(shell: shell, exit: exit)
        }
        if first.hasPrefix("cmd=") {
            // The text may hold ';' once decoded, so everything after the key is the command.
            let encoded = body.dropFirst(4)
            let line = percentDecoded(encoded).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : .command(line)
        }
        return nil
    }

    /// SwiftTerm ends an OSC at some bytes inside UTF-8, so the shell percent-encodes the command.
    static func percentDecoded(_ text: Substring) -> String {
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "%"), index + 2 < source.count,
               let high = hex(source[index + 1]), let low = hex(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

struct FinishedCommand: Equatable, Sendable {
    var line: String
    var started: Date
    var elapsed: TimeInterval
    var exitCode: Int32?
}

/// What the shell said it is doing, one pane at a time.
struct CommandTracker: Equatable, Sendable {
    struct Running: Equatable, Sendable {
        var line: String
        var started: Date
    }

    /// Set by the first prompt report. Until then Aether watches the process group instead.
    private(set) var active = false
    private(set) var shell: String?
    private(set) var running: Running?
    /// The command that last finished, kept so the header can say "Ran git diff".
    private(set) var lastFinished: FinishedCommand?

    /// Returns the command that just ended, if this event ended one.
    mutating func apply(_ event: ShellEvent, at date: Date) -> FinishedCommand? {
        switch event {
        case .command(let line):
            // `exec zsh` replaces the shell, and the new one may not report anything.
            if line.split(whereSeparator: \.isWhitespace).first == "exec" {
                self = CommandTracker()
                return nil
            }
            active = true
            running = Running(line: line, started: date)
            return nil
        case .prompt(let shell, let exit):
            active = true
            if let shell, !shell.isEmpty { self.shell = shell }
            guard let running else { return nil }
            self.running = nil
            let finished = FinishedCommand(line: running.line, started: running.started, elapsed: max(0, date.timeIntervalSince(running.started)), exitCode: exit)
            lastFinished = finished
            return finished
        }
    }
}

// MARK: - Prompt navigation

enum PromptDirection: Sendable {
    case previous, next
}

enum PromptNavigator {
    /// The prompt row to scroll to, or nil when there is none that way. `prompts` is sorted.
    static func target(prompts: [Int], from reference: Int, _ direction: PromptDirection) -> Int? {
        switch direction {
        case .previous: prompts.last { $0 < reference }
        case .next: prompts.first { $0 > reference }
        }
    }

    /// The span of a command's output from its cells' roles, given rows of (row, first output column, last output column).
    static func outputSpan(_ rows: [(row: Int, first: Int, last: Int)]) -> (start: Position, end: Position)? {
        guard let first = rows.first, let last = rows.last else { return nil }
        return (Position(col: first.first, row: first.row), Position(col: last.last, row: last.row))
    }
}

extension AppAction {
    var promptDirection: PromptDirection? {
        switch self {
        case .previousPrompt: .previous
        case .nextPrompt: .next
        default: nil
        }
    }
}

extension AetherTerminal {
    /// ⌘↑, ⌘↓, and ⌘⇧A by default, as set in Settings.
    func promptAction(for event: NSEvent) -> AppAction? {
        guard let pressed = KeyChord.capture(event) else { return nil }
        let keys = AppModel.shared.settings.keys
        for action in [AppAction.previousPrompt, .nextPrompt, .selectLastOutput] {
            let bound = keys.chord(action)
            if !bound.key.isEmpty, bound.key == pressed.key, bound.flags == pressed.flags {
                return action
            }
        }
        return nil
    }

    /// Rows holding the start of a prompt, top to bottom, in the normal screen.
    func promptRows() -> [Int] {
        guard let terminal, !terminal.isCurrentBufferAlternate else { return [] }
        var rows: [Int] = []
        var row = 0
        while terminal.bufferLine(atRow: row) != nil {
            if terminal.semanticPromptMarks(at: row).contains(where: { $0.kind == .initial }) {
                rows.append(row)
            }
            row += 1
        }
        return rows
    }

    /// Scrolls so the previous or next prompt sits at the top. False when the shell never marked one.
    func jumpToPrompt(_ direction: PromptDirection) -> Bool {
        guard let terminal else { return false }
        let prompts = promptRows()
        guard !prompts.isEmpty else { return false }
        let top = terminal.getTopVisibleRow()
        let reference: Int
        if let last = lastPromptJump, last.top == top {
            reference = last.row
        } else if scrollPosition >= 1 {
            // At the bottom, start from the live prompt where the cursor is.
            reference = top + terminal.getCursorLocation().y
        } else {
            reference = top
        }
        guard let row = PromptNavigator.target(prompts: prompts, from: reference, direction) else {
            if direction == .next {
                lastPromptJump = nil
                scroll(toPosition: 1)
            }
            return true
        }
        scrollTo(row: row)
        lastPromptJump = (row, terminal.getTopVisibleRow())
        return true
    }

    /// Selects the output of the newest command that printed something. False when nothing is marked as output.
    func selectLastOutput() -> Bool {
        guard let terminal, !terminal.isCurrentBufferAlternate else { return false }
        let prompts = promptRows()
        guard !prompts.isEmpty else { return false }
        var end = prompts.last ?? 0
        while terminal.bufferLine(atRow: end + 1) != nil { end += 1 }
        let limits = prompts + [end + 1]
        for index in stride(from: prompts.count - 1, through: 0, by: -1) {
            var rows: [(row: Int, first: Int, last: Int)] = []
            for row in limits[index]..<limits[index + 1] {
                guard let line = terminal.bufferLine(atRow: row) else { continue }
                var first: Int?
                var last: Int?
                for col in 0..<min(terminal.cols, line.count) {
                    guard terminal.semanticContent(at: Position(col: col, row: row)) == .output else { continue }
                    let character = terminal.getCharacter(for: line[col])
                    guard character != " ", character != "\u{0}" else { continue }
                    if first == nil { first = col }
                    last = col
                }
                if let first, let last { rows.append((row, first, last)) }
            }
            guard let span = PromptNavigator.outputSpan(rows) else { continue }
            selection.setSelection(start: span.start, end: span.end)
            let top = terminal.getTopVisibleRow()
            if span.start.row < top || span.start.row >= top + terminal.rows {
                scrollTo(row: max(0, span.start.row - 1))
            }
            setNeedsDisplay(bounds)
            return true
        }
        return false
    }

    func performPromptAction(_ action: AppAction) -> Bool {
        if let direction = action.promptDirection {
            return jumpToPrompt(direction)
        }
        if action == .selectLastOutput {
            if !selectLastOutput() { NSSound.beep() }
            return true
        }
        return false
    }
}

// MARK: - Scripts

extension ShellIntegration {
    /// zsh reads this first because ZDOTDIR points here. It puts the real ZDOTDIR back, so .zprofile,
    /// .zshrc, and .zlogin load from where they always do, then loads the hooks after the user's .zshenv.
    static let zshEnv = #"""
    # Aether shell integration. Aether points ZDOTDIR here for the shells it starts.
    # This puts your own ZDOTDIR back, runs your .zshenv, then loads Aether's prompt hooks.
    # Set AETHER_SHELL_INTEGRATION=0 in your .zshenv to skip the hooks.
    if [[ -n "${AETHER_ORIG_ZDOTDIR+X}" ]]; then
        builtin export ZDOTDIR="$AETHER_ORIG_ZDOTDIR"
        builtin unset AETHER_ORIG_ZDOTDIR
    else
        builtin unset ZDOTDIR
    fi

    {
        builtin typeset _aether_file="${ZDOTDIR-$HOME}/.zshenv"
        [[ ! -r "$_aether_file" ]] || builtin source -- "$_aether_file"
    } always {
        if [[ -o interactive && "${AETHER_SHELL_INTEGRATION-1}" != 0 ]]; then
            _aether_file="${${(%):-%x}:A:h}/aether-integration"
            if [[ -r "$_aether_file" ]]; then
                builtin autoload -Uz -- "$_aether_file"
                aether-integration
                builtin unfunction aether-integration 2>/dev/null
            fi
        fi
        builtin unset _aether_file
    }
    """#

    /// Runs as an autoloaded function, so the user's aliases and options cannot reach into it.
    /// Nothing is printed until the first prompt, which keeps powerlevel10k's instant prompt quiet.
    static let zshIntegration = #"""
    # Aether prompt hooks for zsh. Loaded from Aether's .zshenv in interactive shells.
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    (( ! $+_aether_state )) || builtin return 0

    # 0 before the first prompt, 1 while a command runs, 2 at a prompt.
    builtin typeset -gi _aether_state=0
    builtin typeset -gi _aether_fd=1
    # Write to the terminal itself, so a redirected stdout, or an instant prompt
    # capturing it, never sees these sequences.
    {
        builtin zmodload zsh/system && (( $+builtins[sysopen] )) &&
            [[ -w /dev/tty ]] && builtin sysopen -o cloexec -wu _aether_fd -- /dev/tty
    } 2>/dev/null || _aether_fd=1

    # Percent-encodes $1 into REPLY.
    _aether_encode() {
        builtin emulate -L zsh -o no_multibyte
        builtin local LC_ALL=C text=$1 out= ch
        if [[ $text != *[^A-Za-z0-9/._~-]* ]]; then
            REPLY=$text
            builtin return 0
        fi
        builtin local -i i code
        for (( i = 1; i <= ${#text}; i++ )); do
            ch=$text[i]
            if [[ $ch == [A-Za-z0-9/._~-] ]]; then
                out+=$ch
            else
                (( code = #ch & 255 ))
                builtin printf -v ch '%%%02X' $code
                out+=$ch
            fi
        done
        REPLY=$out
    }

    _aether_title() {
        [[ ${AETHER_SHELL_TITLE-1} != 0 ]] || builtin return 0
        builtin emulate -L zsh -o no_multibyte
        # Only printable ASCII: SwiftTerm ends an OSC at some bytes inside UTF-8.
        builtin local LC_ALL=C title=${1//[$'\t\n\r']/ }
        title=${title//[^ -~]/}
        builtin print -rnu $_aether_fd -- $'\e]2;'"$title"$'\a'
    }

    _aether_report_pwd() {
        builtin emulate -L zsh -o no_warn_create_global -o no_aliases
        builtin local REPLY
        _aether_encode "$PWD"
        builtin print -rnu $_aether_fd -- $'\e]7;file://'"$HOST$REPLY"$'\a'
    }

    _aether_precmd() {
        builtin local -i code=$?
        builtin emulate -L zsh -o no_warn_create_global -o no_aliases
        # A plugin may run precmd hooks from inside the line editor. Report nothing then.
        if ! builtin zle; then
            builtin local tail=
            if (( _aether_state == 1 )); then
                builtin print -rnu $_aether_fd -- $'\e]133;D;'$code$'\a'
                tail=";exit=$code"
            fi
            _aether_report_pwd
            _aether_title "zsh ${(%):-%~}"
            builtin print -rnu $_aether_fd -- $'\e]7502;prompt;shell=zsh'"$tail"$'\a'
            (( _aether_state = 2 ))
        fi
        if [[ ! -o prompt_percent ]]; then
            builtin zle || builtin print -rnu $_aether_fd -- $'\e]133;A\a'
            builtin return 0
        fi
        if [[ ${precmd_functions[-1]} != _aether_precmd ]]; then
            # A hook after this one could rebuild PS1. Go last next time, and mark this prompt directly.
            # powerlevel10k always moves itself last and rebuilds PS1, so leave it there.
            [[ ${precmd_functions[-1]} == _p9k_precmd ]] ||
                precmd_functions=(${precmd_functions:#_aether_precmd} _aether_precmd)
            builtin zle || builtin print -rnu $_aether_fd -- $'\e]133;A\a'
            builtin return 0
        fi
        # Marks inside PS1 come back whenever zsh redraws the prompt. Start from the
        # unmarked prompt when nothing else touched it since the last time.
        if [[ -n ${_aether_ps1+x} && $PS1 == "$_aether_marked" ]]; then
            PS1=$_aether_ps1
            PS2=$_aether_ps2
        fi
        _aether_ps1=$PS1
        _aether_ps2=$PS2
        # A bare trailing % would swallow the { of the mark.
        [[ $PS1 == *[^%]% || $PS1 == % ]] && PS1+=%
        [[ $PS2 == *[^%]% || $PS2 == % ]] && PS2+=%
        PS1=$'%{\e]133;A\a%}'$PS1$'%{\e]133;B\a%}'
        PS2=$'%{\e]133;P;k=s\a%}'$PS2$'%{\e]133;B\a%}'
        _aether_marked=$PS1
    }

    _aether_preexec() {
        builtin emulate -L zsh -o no_warn_create_global -o no_aliases
        # Other preexec hooks and the command itself see the prompt without marks.
        if [[ -n ${_aether_ps1+x} && $PS1 == "$_aether_marked" ]]; then
            PS1=$_aether_ps1
            PS2=$_aether_ps2
        fi
        _aether_title "$1"
        builtin local REPLY
        _aether_encode "${1[1,1024]}"
        builtin print -rnu $_aether_fd -- $'\e]7502;cmd='"$REPLY"$'\a\e]133;C\a'
        (( _aether_state = 1 ))
    }

    # Hooks go in at the first prompt, after .zshrc, so they run after the user's own.
    _aether_deferred_init() {
        builtin emulate -L zsh -o no_warn_create_global -o no_aliases
        builtin autoload -Uz add-zsh-hook
        add-zsh-hook preexec _aether_preexec
        add-zsh-hook chpwd _aether_report_pwd
        builtin typeset -ag precmd_functions
        precmd_functions=(${precmd_functions:#_aether_deferred_init} _aether_precmd)
        _aether_precmd
        builtin unfunction _aether_deferred_init
    }

    builtin typeset -ag precmd_functions
    precmd_functions+=(_aether_deferred_init)
    """#

    /// Bash ignores --rcfile in a login shell, so Aether starts it interactive with this file,
    /// which runs /etc/profile and the first of ~/.bash_profile, ~/.bash_login, ~/.profile, as login does.
    static let bashIntegration = #"""
    # Aether shell integration for bash. Aether starts bash with --rcfile pointing here,
    # so this file runs the usual login files first, then adds prompt hooks.
    # Set AETHER_SHELL_INTEGRATION=0 in your profile to skip the hooks.
    if [[ -n "${AETHER_BASH_LOGIN-}" ]]; then
        builtin unset AETHER_BASH_LOGIN
        if [[ -r /etc/profile ]]; then builtin source /etc/profile; fi
        if [[ -r ~/.bash_profile ]]; then builtin source ~/.bash_profile
        elif [[ -r ~/.bash_login ]]; then builtin source ~/.bash_login
        elif [[ -r ~/.profile ]]; then builtin source ~/.profile
        fi
    elif [[ -r ~/.bashrc ]]; then
        builtin source ~/.bashrc
    fi

    if [[ "${AETHER_SHELL_INTEGRATION-1}" != 0 && -z "${__aether_loaded-}" && $- == *i* ]]; then
    __aether_loaded=1
    __aether_running=
    __aether_armed=

    # Percent-encodes $1 into __aether_reply.
    __aether_encode() {
        builtin local LC_ALL=C text="$1" out= ch hex i
        case $text in
            *[!A-Za-z0-9/._~-]*) ;;
            *) __aether_reply=$text; builtin return 0 ;;
        esac
        for (( i = 0; i < ${#text}; i++ )); do
            ch=${text:i:1}
            case $ch in
                [A-Za-z0-9/._~-]) out+=$ch ;;
                *) builtin printf -v hex '%02X' "'$ch"; out+="%${hex: -2}" ;;
            esac
        done
        __aether_reply=$out
    }

    __aether_title() {
        [[ "${AETHER_SHELL_TITLE-1}" != 0 ]] || builtin return 0
        builtin local LC_ALL=C title="$1"
        title=${title//[$'\t\n\r']/ }
        title=${title//[^ -~]/}
        builtin printf '\e]2;%s\a' "$title"
    }

    __aether_precmd() {
        builtin local code=$? tail= here="$PWD"
        if [[ -n $__aether_running ]]; then
            builtin printf '\e]133;D;%s\a' "$code"
            tail=";exit=$code"
            __aether_running=
        fi
        __aether_encode "$PWD"
        builtin printf '\e]7;file://%s%s\a' "$HOSTNAME" "$__aether_reply"
        if [[ $here == "$HOME" ]]; then here='~'
        elif [[ $here == "$HOME"/* ]]; then here="~/${here#"$HOME"/}"
        fi
        __aether_title "bash $here"
        builtin printf '\e]7502;prompt;shell=bash%s\a' "$tail"
        builtin return $code
    }

    # Runs last, after anything that rebuilds PS1, such as starship.
    __aether_prompt_end() {
        builtin local code=$?
        if [[ $PS1 != *'133;A'* ]]; then
            PS1="\[\e]133;A\a\]$PS1\[\e]133;B\a\]"
        fi
        __aether_armed=1
        builtin return $code
    }

    __aether_preexec() {
        __aether_running=1
        __aether_title "$1"
        __aether_encode "${1:0:1024}"
        builtin printf '\e]7502;cmd=%s\a\e]133;C\a' "$__aether_reply"
    }

    # The DEBUG trap fires before every simple command. Only the first one after a prompt is the user's.
    __aether_debug() {
        [[ -n $__aether_armed ]] || builtin return 0
        [[ -z "${COMP_LINE-}" ]] || builtin return 0
        __aether_armed=
        case $BASH_COMMAND in
            __aether_precmd*|__aether_prompt_end*) builtin return 0 ;;
        esac
        builtin local line re='^[[:space:]]*[0-9]+[*]?[[:space:]]+'
        line=$(HISTTIMEFORMAT= builtin history 1)
        if [[ $line == "$__aether_history" ]]; then
            # Not added to history (ignorespace, ignoredups, or history off).
            line=$BASH_COMMAND
        else
            __aether_history=$line
            [[ $line =~ $re ]] && line=${line:${#BASH_REMATCH[0]}}
        fi
        __aether_preexec "$line"
    }

    if [[ -n "${bash_preexec_imported-}${__bp_imported-}" ]]; then
        # bash-preexec already owns the DEBUG trap and PROMPT_COMMAND. Join its hooks.
        __aether_bp_preexec() { __aether_preexec "$1"; }
        precmd_functions=(__aether_precmd "${precmd_functions[@]}" __aether_prompt_end)
        preexec_functions+=(__aether_bp_preexec)
    else
        __aether_history=$(HISTTIMEFORMAT= builtin history 1)
        __aether_trap=$(builtin trap -p DEBUG)
        __aether_trap=${__aether_trap#"trap -- '"}
        __aether_trap=${__aether_trap%"' DEBUG"}
        __aether_trap=${__aether_trap//"'\\''"/"'"}
        if [[ -n $__aether_trap ]]; then
            # Keep a DEBUG trap that is already there, such as starship's, and run it first.
            builtin trap "$__aether_trap"$'\n''__aether_debug' DEBUG
        else
            builtin trap '__aether_debug' DEBUG
        fi
        builtin unset __aether_trap
        if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
            PROMPT_COMMAND=(__aether_precmd "${PROMPT_COMMAND[@]}" __aether_prompt_end)
        else
            PROMPT_COMMAND=$'__aether_precmd\n'"${PROMPT_COMMAND-}"$'\n__aether_prompt_end'
        fi
    fi
    fi
    """#

    /// Fish runs vendor_conf.d snippets before config.fish. Fish sets titles itself, so this sends none.
    static let fishIntegration = #"""
    # Aether shell integration for fish. Aether adds this folder to XDG_DATA_DIRS for the shells
    # it starts; the folder comes back out here, so programs started from fish never see it.
    if set -q AETHER_FISH_DATA_DIR
        if set -q AETHER_ORIG_XDG_DATA_DIRS
            set -gx XDG_DATA_DIRS $AETHER_ORIG_XDG_DATA_DIRS
            set -e AETHER_ORIG_XDG_DATA_DIRS
        else
            set -e XDG_DATA_DIRS
        end
        set -e AETHER_FISH_DATA_DIR
    end

    status is-interactive; or exit 0
    test "$AETHER_SHELL_INTEGRATION" = 0; and exit 0
    set -q __aether_loaded; and exit 0
    set -g __aether_loaded 1

    function __aether_encode
        string join / (string escape --style=url -- (string split / -- $argv[1]))
    end

    function __aether_preexec --on-event fish_preexec
        set -g __aether_running 1
        printf '\e]7502;cmd=%s\a\e]133;C\a' (__aether_encode (string sub -l 1024 -- "$argv[1]"))
    end

    function __aether_postexec --on-event fish_postexec
        set -g __aether_status $status
    end

    function __aether_status
        return $argv[1]
    end

    function __aether_prompt --on-event fish_prompt
        set -l tail
        if set -q __aether_running
            printf '\e]133;D;%s\a' $__aether_status
            set tail ";exit=$__aether_status"
            set -e __aether_running
        end
        printf '\e]7;file://%s%s\a' $hostname (__aether_encode $PWD)
        printf '\e]7502;prompt;shell=fish%s\a' "$tail"
        printf '\e]133;A\a'
        # config.fish has run by the first prompt, so its fish_prompt is the one to wrap.
        if not set -q __aether_wrapped; and functions -q fish_prompt
            set -g __aether_wrapped 1
            functions -c fish_prompt __aether_original_prompt
            function fish_prompt
                __aether_status $status
                __aether_original_prompt
                printf '\e]133;B\a'
            end
        end
    end
    """#
}
