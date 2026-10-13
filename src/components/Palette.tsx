import { useEffect, useMemo, useRef, useState } from 'react'
import { launchCommand, runPaletteAction } from '../lib/actions'
import { buildPalette, type PaletteItem } from '../lib/commands'
import { prettyPath } from '../lib/format'
import { useStore } from '../lib/store'
import { useUi } from '../lib/ui'

function runItem(item: PaletteItem) {
  const store = useStore.getState()
  if (item.kind === 'run' || item.kind === 'recent') {
    if (item.command) launchCommand(item.command, item.cwd)
    return
  }
  if (item.kind === 'profile' && item.command) {
    launchCommand(item.command, item.cwd || undefined)
    return
  }
  if (item.kind === 'action' && item.action) {
    runPaletteAction(item.action)
    return
  }
  if (item.kind === 'pane' && item.paneId) {
    store.focus(item.paneId)
    useUi.getState().setPalette(false)
    return
  }
  if (item.kind === 'workspace' && item.workspaceId) {
    store.switchWorkspace(item.workspaceId)
    useUi.getState().setPalette(false)
    return
  }
  if (item.kind === 'theme' && item.themeId) {
    store.patchSettings({ themeId: item.themeId, accent: null })
    useUi.getState().setPalette(false)
  }
}

export function Palette() {
  const open = useUi((state) => state.palette)
  const panes = useStore((state) => state.panes)
  const workspaces = useStore((state) => state.workspaces)
  const profiles = useStore((state) => state.profiles)
  const recent = useStore((state) => state.recent)
  const home = useStore((state) => state.home)
  const cwd = useStore((state) => {
    const workspace = state.active()
    return workspace.focusedId ? state.panes[workspace.focusedId]?.cwd ?? state.home : state.home
  })
  const [query, setQuery] = useState('')
  const [cursor, setCursor] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)

  const items = useMemo(
    () => buildPalette(query, { panes: Object.values(panes), workspaces, profiles, recent }),
    [panes, profiles, query, recent, workspaces],
  )

  useEffect(() => {
    if (!open) return
    setQuery('')
    setCursor(0)
    const frame = requestAnimationFrame(() => inputRef.current?.focus())
    return () => cancelAnimationFrame(frame)
  }, [open])

  useEffect(() => setCursor(0), [query])

  if (!open) return null
  const selected = Math.min(cursor, Math.max(0, items.length - 1))

  return (
    <div className="palette-backdrop" onMouseDown={() => useUi.getState().setPalette(false)}>
      <div className="palette" role="dialog" aria-label="Commands" onMouseDown={(event) => event.stopPropagation()}>
        <input
          ref={inputRef}
          data-field="aether"
          value={query}
          placeholder="Run a command, or search"
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'ArrowDown') {
              event.preventDefault()
              setCursor((value) => Math.min(items.length - 1, value + 1))
            } else if (event.key === 'ArrowUp') {
              event.preventDefault()
              setCursor((value) => Math.max(0, value - 1))
            } else if (event.key === 'Enter' && items[selected]) {
              event.preventDefault()
              runItem(items[selected])
            } else if (event.key === 'Escape') {
              useUi.getState().setPalette(false)
            }
          }}
        />
        <div className="palette-list" role="listbox">
          {items.map((item, index) => (
            <button
              key={item.id}
              role="option"
              aria-selected={index === selected}
              className={index === selected ? 'on' : ''}
              onMouseEnter={() => setCursor(index)}
              onClick={() => runItem(item)}
            >
              <span>{item.title}</span>
              {item.hint ? <em>{item.hint}</em> : null}
            </button>
          ))}
          {!items.length ? <p className="quiet">Nothing matches.</p> : null}
        </div>
        <footer>Starts in {prettyPath(cwd, home) || '~'}</footer>
      </div>
    </div>
  )
}
