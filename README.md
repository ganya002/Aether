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

The shell still receives Control, so Control-C is the shell's. Option types the macOS character.

| Keys | Action |
| --- | --- |
| ⌘N | New window |
| ⌘T | New terminal in this window |
| ⌘K | Launch a command or search actions |
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
| ⌃⌘` | Dropdown terminal |
| ⌘, | Settings |

⌘⇧L cycles the layout of the panes you already have: Tall, Fat, Grid, Columns, Rows, then Stack. Tall keeps the focused pane large on the left. Fat puts it across the top. Stack shows one pane at a time, and the arrow keys move through the stack. A new terminal joins the current layout. ⌘D still makes a manual split.

Drag the six dots on a pane to drop it on an edge, swap it with another pane, or pull it off into a new window. Drag the rest of the pane's title to move the window. While you resize a window, the panes frost over and darken, then ease back when you let go.

⌘K runs whatever you type (`btop`, `nvim`, `ssh`, a pipeline) in a new terminal. ⌘↩ in that launcher opens it in a new window.

Shade, glass style, type size, focus, and snap behavior live in Settings. The default glass is Regular. Clear is the window server bending whatever is actually behind Aether, with only enough shade to keep the type readable.

Unfocused panes dim by default. Settings can blur them, or leave them as they are. The focused pane keeps a white rim either way. Switching focus eases the rim and the dim together.

⌃⌘` drops a terminal down from the top of the screen, from any app. ⌘-click a path to open it. A command that runs for a couple of seconds posts a notification if Aether is in the background. The scrollbar shows while you scroll, and the magnifying glass on the focused pane is Find.

The portable settings file is `~/Library/Application Support/Aether/config.json`. Sessions, including open panes, stay in `session.json` beside it. Processes start again in the directory they were left in.
