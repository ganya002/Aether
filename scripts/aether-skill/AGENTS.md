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
| `config` | `path`, `check`, or `defaults` for `~/.config/aether/config`. |
| `imgcat` | Draw an image inline (kitty graphics and sixel work too). |
| `close` | Close a pane you opened. |
| `screenshot` | PNG of a pane. |
| `mcp` | MCP stdio, one tool per command. |

`aether help <command>` has flags and examples.

Exit codes: 0 ok, 1 Aether refused or is not running, 2 bad arguments.
