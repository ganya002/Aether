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
