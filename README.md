# Aether

A native macOS terminal. Every pane is a real shell, and the window is Liquid Glass: it refracts whatever is actually behind it. There is no wallpaper image and no browser.

Open as many windows as you want, split them, and drag a pane out into a window of its own. Windows snap to each other when you let go. Hold Option to skip the snap.

Requires macOS 26 or later.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ganya002/Aether/main/scripts/install.sh | bash
```

That builds Aether, puts it in Downloads, and opens it. The first time it starts, it asks you to drag it into Applications.

## Build

```bash
./scripts/build-app.sh
open dist/Aether.app
```

`swift test` checks the layout engine.

## Daily keys

The shell still receives Control, so Control-C is the shell's. Option types the macOS character, and Settings can make it Meta (or only the left Option key). ⌥← / ⌥→ move by word, ⌥⌫ deletes a word, and ⌘← / ⌘→ / ⌘⌫ go to the start of the line, the end, or erase back to the start.

| Keys | Action |
| --- | --- |
| ⌘N | New window |
| ⌘T | New terminal in this window |
| ⌘P | Launch a command or search actions |
| ⌘K | Clear the terminal and its scrollback |
| ⌘D / ⌘⇧D | Split right / split down |
| ⌘W | Close the focused terminal |
| ⌘⇧W | Close the window |
| ⌘↩ | Fill the window with the focused terminal |
| ⌘⌥ arrows | Focus the neighbor |
| ⌘⇧ arrows | Resize the split |
| ⌘⇧L / ⌘⌥⇧L | Next / previous layout |
| ⌘⇧E | Equalize splits |
| ⌘B | Broadcast keys to every terminal in the window |
| ⌘F | Find |
| ⌘⇧P | Insert a path from the current folder |
| ⌃⌘` | Dropdown terminal |
| ⌘, | Settings |

⌘⇧L cycles the layout of the panes you already have: Tall, Fat, Grid, Columns, Rows, then Stack. Tall keeps the focused pane large on the left. Fat puts it across the top. Stack shows one pane at a time, and the arrow keys move through the stack. A new terminal joins the current layout. ⌘D still makes a manual split.

Drag the six dots on a pane to drop it on an edge, swap it with another pane, or pull it off into a new window. Drag the rest of the pane's title to move the window. While you resize a window, the panes frost over and darken, then ease back when you let go.

⌘P runs whatever you type (`btop`, `nvim`, `ssh`, a pipeline) in a new terminal. ⌘↩ in that launcher opens it in a new window. If you saved shortcuts before ⌘K became Clear, the launcher moves to ⌘P on its own unless you had changed it.

⌘K clears the screen and the scrollback and keeps the prompt, as it does in Terminal.app. Edit › Clear Scrollback does the same.

Closing a terminal, a window, or Aether while something is running asks first, and names what is running. Settings can make it always ask, or never. A shell that exits cleanly closes its terminal; a command that fails leaves Restart (↩) and Close (Esc). Pasting several lines into a shell without bracketed paste asks before it runs them.

While ⌘B is on, every terminal in the window gets an amber outline and a Broadcasting tag, and what you type goes to all of them.

Shade, glass style, type size, focus, and snap behavior live in Settings. The default glass is Regular. Clear is the window server bending whatever is actually behind Aether, with only enough shade to keep the type readable.

Unfocused panes dim by default. Settings can blur them, or leave them as they are. The focused pane has a border. Switching focus eases that border and the dim together.

⌃⌘` drops a terminal down from the top of the screen, from any app. ⌘-click a path to open it. A command that runs for 10 seconds or more posts a notification if Aether is in the background, with its name, whether it worked, and how long it took. Click it to go back to that terminal. `notifyAfterSeconds` in config.json changes the wait. The scrollbar shows while you scroll, and the magnifying glass on the focused pane is Find.

The portable settings file is `~/Library/Application Support/Aether/config.json`. Sessions, including open panes, stay in `session.json` beside it. Terminals reopen as shells in the directory they were left in. A terminal that was running a command does not run it again; it offers Run Again instead. If config.json stops being valid JSON, Aether moves it aside as `config.json.bad-<time>`, says so, and starts with defaults. A single bad value only resets that setting.

## Credits

Built by Gabby (ganya002), with help from Botty (Grokky-Bot-Cutie).
