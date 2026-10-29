---
name: aether
description: Control the Aether terminal from a shell. Open panes, type into them, run commands to completion, read output, and close panes you opened.
---

You are in Aether when `AETHER_PANE` is set. Use the `aether` command. Do not guess keystrokes for splits.

Every command acts on your own pane (`AETHER_PANE`) unless you pass `--pane <id>`. Pane ids may be positional (`aether read 50BBAE3B`) or given as `--pane`. Outside Aether, with one window open that window is used; with several, pass `--pane`, `--window`, or `--desk`. Commands never move keyboard focus unless you pass `--focus`. Add `--json` to any command for the raw reply.

Agent loop: spawn with `tab` or `run`, watch with `wait` / `read`, interrupt with `send --keys ctrl+c`, rerun with `run` or `send`.

- `aether split --right --ratio 30 -- npm run dev` opens a terminal beside you and prints its id. Sides: `--right`, `--left`, `--up`, `--down`.
- `aether tab -- command` adds a terminal to your window and prints its id.
- `aether run -- make test` runs a command in a new tab, streams output, and exits with that command's status. `aether run --pane <id> -- npm test` types into an existing pane and waits until the shell is idle.
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
- `aether font 1` or `aether font -1` changes the type size. `aether font 0` resets it.
- `aether skill` installs this skill and AGENTS.md.
- `aether mcp` speaks MCP on stdin/stdout (one tool per command).
- `aether help <command>` shows options and examples.

Exit codes: 0 worked, 1 Aether refused or is not running (the reason is on stderr), 2 bad arguments. `aether run` exits with the command's own status.

"Beside you" means split your own pane. Leave focus alone unless asked. Close only panes you opened, and close them when you are done with them.
