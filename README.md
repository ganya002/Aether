# Aether

A native macOS terminal. Every pane is a real shell, and the window is Liquid Glass: it refracts whatever is actually behind it. There is no wallpaper image and no browser.

Open as many windows as you want, split them, and drag a pane out into a window of its own. Windows snap to each other when you let go. Hold Option to skip the snap.

Requires macOS 26 or later.

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
| ⌘⇧E | Equalize splits |
| ⌘B | Broadcast keys to every terminal in the window |
| ⌘F | Find |
| ⌘, | Settings |

Drag the six dots on a pane to drop it on an edge, swap it with another pane, or pull it off into a new window. Drag the rest of the pane's title to move the window.

⌘K runs whatever you type (`btop`, `nvim`, `ssh`, a pipeline) in a new terminal. ⌘↩ in that launcher opens it in a new window.

Shade, glass style, type size, and snap behavior live in Settings. Shade only exists so the type stays readable. Turn it down to see more of the desktop through the glass.

Sessions are remembered in `~/Library/Application Support/Aether/session.json`. Processes start again in the directory they were left in.
