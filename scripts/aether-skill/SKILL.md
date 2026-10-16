---
name: aether
description: Control the Aether terminal the agent is running in. Open tabs, split panes, place a page or PDF, change type size, and read the screen.
---

You are in Aether when `AETHER_PANE` is set. Run `aether` to change the layout. Do not guess keystrokes for splits.

- `aether split --split right --ratio 30 -- command` places a terminal on the right, left, top, or bottom. Ratio is the new pane's share, from 10 to 80.
- `aether tab -- command` opens another terminal.
- `aether open web https://example.com --split right --ratio 40` shows a page in a pane.
- `aether open pdf /path/file.pdf --split bottom` shows a PDF in a pane.
- `aether font --delta 1` or `--delta -1` changes the type size. `--delta 0` resets it.
- `aether zoom` fills the window with the focused pane.
- `aether read` prints the focused terminal's screen.
- `aether view` prints the panes.

"Beside you" means split the pane in `AETHER_PANE`. Leave focus alone unless asked. Close only panes you opened.
