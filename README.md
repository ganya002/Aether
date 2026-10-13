# Aether

A glass desk for every CLI. Aether tiles as many real terminals as you want on one wallpaper, with the panes translucent enough that the background shows through. It is a local app: one small Node process on your machine, no Electron, and your shells never leave it.

Drag a pane onto another to split or swap. Drag the gaps to resize. Switch a desk to freeform and place windows anywhere, with edges that snap. Launch `vim`, `lazygit`, `ssh`, a repl, or whatever is on your `PATH` — each pane is a real PTY with color, unicode, and mouse reporting.

## Run it

```bash
npm install
npm start
```

Then open [http://127.0.0.1:41773](http://127.0.0.1:41773).

On a Mac, `npm run mac` starts the server and opens a chromeless Chrome, Edge, or Brave window you can keep in the Dock. That uses the browser you already have, which is lighter than shipping a second one.

The desk is saved in `~/Library/Application Support/Aether` on macOS and `~/.config/aether` on Linux. Uploaded wallpapers live there too.

## Daily keys

On a Mac the modifier is ⌘. On Linux and Windows it is Ctrl. The shell still receives Ctrl-C, and on a Mac it still receives Ctrl for readline.

| Keys | Action |
| --- | --- |
| ⌘K | Run a command, or search panes and actions |
| ⌘T | New terminal |
| ⌘D / ⌘⇧D | Split right / split down |
| ⌘W | Close the focused pane |
| ⌘↩ | Fill the desk with the focused pane |
| ⌘⌥ arrows | Focus the neighbor |
| ⌘⇧ arrows | Resize |
| ⌘B | Broadcast keys to every pane on the desk |
| ⌘E | Tile or freeform |
| ⌘F | Find in the focused pane |
| ⌘, | Settings |

Drop an image on the wallpaper to use it as the background. Drop a file on a pane to paste its path.

## Low power

The default look is frosted glass on a still image. WebGL is off, because many panes each holding a GL context costs more than the canvas renderer. Hidden desks unmount their renderers; the processes keep running so a dev server survives a desk switch.

Turn on **Low power** in the Look panel to drop blur, grain, and motion. Turn scrollback down in Settings if you keep dozens of shells open.

## Scripts

```bash
npm test
npm run typecheck
npm run build && npm run serve
```
