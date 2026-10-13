import { useEffect, useState } from 'react'
import { prettyPath } from '../lib/format'
import { chordLabel } from '../lib/keys'
import { snapRect, zoneAt, type Zone } from '../lib/layout'
import { useStore } from '../lib/store'
import { termApi } from '../lib/terms'
import { toast, useUi, type MenuItem } from '../lib/ui'
import { TerminalView } from './TerminalView'

function hitPane(x: number, y: number, sourceId: string) {
  const nodes = document.querySelectorAll<HTMLElement>('[data-pane]')
  for (const node of nodes) {
    const paneId = node.dataset.pane
    if (!paneId || paneId === sourceId) continue
    const rect = node.getBoundingClientRect()
    if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) continue
    return {
      targetId: paneId,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      zone: zoneAt(x, y, rect) as Zone,
    }
  }
  return null
}

export function Pane({ id }: { id: string }) {
  const pane = useStore((state) => state.panes[id])
  const home = useStore((state) => state.home)
  const focused = useStore((state) => state.active().focusedId === id)
  const broadcast = useStore((state) => state.active().broadcast)
  const mode = useStore((state) => state.active().mode)
  const locked = useStore((state) => state.active().locked)
  const findId = useUi((state) => state.findId)
  const palette = useUi((state) => state.palette)
  const settingsOpen = useUi((state) => state.settings)
  const look = useUi((state) => state.look)
  const [renaming, setRenaming] = useState(false)
  const [draft, setDraft] = useState('')
  const [query, setQuery] = useState('')
  const [bell, setBell] = useState(false)

  useEffect(() => {
    if (!focused || palette || settingsOpen || look || renaming) return
    if (document.activeElement?.matches('[data-field="aether"]')) return
    termApi(id)?.focus()
  }, [focused, id, look, palette, renaming, settingsOpen])

  useEffect(() => {
    if (!bell) return
    const timer = window.setTimeout(() => setBell(false), 460)
    return () => window.clearTimeout(timer)
  }, [bell])

  if (!pane) return null

  const openMenu = (x: number, y: number) => {
    const store = useStore.getState()
    const desks = store.workspaces.filter((workspace) => workspace.id !== store.activeWorkspaceId)
    const items: MenuItem[] = [
      { id: 'copy', label: 'Copy', hint: chordLabel('c'), onSelect: () => void termApi(id)?.copy().then(() => toast('Copied')).catch(() => toast('Nothing selected')) },
      { id: 'paste', label: 'Paste', hint: chordLabel('v'), onSelect: () => void termApi(id)?.paste().catch(() => toast('Clipboard blocked')) },
      { id: 'all', label: 'Select all', onSelect: () => termApi(id)?.selectAll() },
      { id: 'clear', label: 'Clear', hint: chordLabel('k', { shift: true }), onSelect: () => termApi(id)?.clear() },
      { id: 'find', label: 'Find', hint: chordLabel('f'), onSelect: () => useUi.getState().setFind(id) },
      { id: 'rename', label: 'Rename', onSelect: () => { setDraft(pane.title); setRenaming(true) } },
      { id: 'split', label: 'Split right', hint: chordLabel('d'), onSelect: () => store.split('right') },
      { id: 'down', label: 'Split down', hint: chordLabel('d', { shift: true }), onSelect: () => store.split('down') },
      { id: 'dup', label: 'Duplicate shell here', onSelect: () => store.duplicate(id) },
      { id: 'mute', label: pane.muted ? 'Include in broadcast' : 'Mute for broadcast', onSelect: () => store.toggleMute(id) },
      { id: 'max', label: 'Fill the desk', hint: chordLabel('Enter'), onSelect: () => store.toggleMaximize(id) },
      { id: 'min', label: 'Move to shelf', hint: chordLabel('m'), onSelect: () => store.minimize(id) },
      ...desks.map((workspace) => ({
        id: `move-${workspace.id}`,
        label: `Move to ${workspace.name}`,
        onSelect: () => store.moveToWorkspace(id, workspace.id),
      })),
      { id: 'close', label: 'Close', hint: chordLabel('w'), danger: true, onSelect: () => store.closePane(id) },
    ]
    useUi.getState().openMenu(x, y, items)
  }

  const onTitlePointerDown = (event: React.PointerEvent) => {
    if (event.button !== 0) return
    if ((event.target as HTMLElement).closest('button, input')) return
    const store = useStore.getState()
    store.focus(id)
    const workspace = store.active()
    if (workspace.locked) return
    const startX = event.clientX
    const startY = event.clientY
    const frame = (event.currentTarget as HTMLElement).closest('[data-anchored]') as HTMLElement | null
    const stage = (event.currentTarget as HTMLElement).closest('.stage') as HTMLElement | null
    const origin = frame?.getBoundingClientRect()
    const stageBox = stage?.getBoundingClientRect()
    let moved = false
    let latest = workspace.rects[id]
    const move = (ev: PointerEvent) => {
      if (!moved && Math.hypot(ev.clientX - startX, ev.clientY - startY) < 5) return
      moved = true
      if (workspace.mode === 'free' && frame && origin && stageBox) {
        document.body.dataset.dragging = 'free'
        document.body.dataset.dragId = id
        const rect = {
          x: (origin.left + (ev.clientX - startX) - stageBox.left) / stageBox.width,
          y: (origin.top + (ev.clientY - startY) - stageBox.top) / stageBox.height,
          w: origin.width / stageBox.width,
          h: origin.height / stageBox.height,
        }
        const others = Object.entries(useStore.getState().active().rects)
          .filter(([paneId]) => paneId !== id)
          .map(([, box]) => box)
        const snapped = snapRect(rect, others)
        frame.style.left = `${snapped.rect.x * 100}%`
        frame.style.top = `${snapped.rect.y * 100}%`
        latest = snapped.rect
        useUi.getState().setDrag({ kind: 'free', guides: snapped.guides })
        return
      }
      useUi.getState().setDrag({
        kind: 'tile',
        id,
        title: pane.title,
        accent: pane.accent,
        x: ev.clientX,
        y: ev.clientY,
        drop: hitPane(ev.clientX, ev.clientY, id),
      })
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      const drag = useUi.getState().drag
      useUi.getState().setDrag(null)
      delete document.body.dataset.dragging
      delete document.body.dataset.dragId
      if (!moved) return
      if (workspace.mode === 'free' && latest) {
        useStore.getState().setRect(id, latest)
        return
      }
      if (drag?.kind === 'tile' && drag.drop) useStore.getState().move(id, drag.drop.targetId, drag.drop.zone)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  const onResize = (edge: string, event: React.PointerEvent) => {
    if (mode !== 'free' || locked) return
    event.preventDefault()
    event.stopPropagation()
    const frame = (event.currentTarget as HTMLElement).closest('[data-anchored]') as HTMLElement | null
    const stage = frame?.closest('.stage') as HTMLElement | null
    if (!frame || !stage) return
    const origin = frame.getBoundingClientRect()
    const stageBox = stage.getBoundingClientRect()
    const startX = event.clientX
    const startY = event.clientY
    const base = {
      x: (origin.left - stageBox.left) / stageBox.width,
      y: (origin.top - stageBox.top) / stageBox.height,
      w: origin.width / stageBox.width,
      h: origin.height / stageBox.height,
    }
    document.body.dataset.dragging = 'free'
    document.body.dataset.dragId = id
    let latest = base
    const move = (ev: PointerEvent) => {
      const dx = (ev.clientX - startX) / stageBox.width
      const dy = (ev.clientY - startY) / stageBox.height
      let { x, y, w, h } = base
      if (edge.includes('e')) w += dx
      if (edge.includes('s')) h += dy
      if (edge.includes('w')) {
        x += dx
        w -= dx
      }
      if (edge.includes('n')) {
        y += dy
        h -= dy
      }
      w = Math.max(0.18, w)
      h = Math.max(0.16, h)
      x = Math.min(Math.max(0, x), 1 - w)
      y = Math.min(Math.max(0, y), 1 - h)
      const others = Object.entries(useStore.getState().active().rects)
        .filter(([paneId]) => paneId !== id)
        .map(([, box]) => box)
      const snapped = snapRect({ x, y, w, h }, others, 0.012)
      frame.style.left = `${snapped.rect.x * 100}%`
      frame.style.top = `${snapped.rect.y * 100}%`
      frame.style.width = `${snapped.rect.w * 100}%`
      frame.style.height = `${snapped.rect.h * 100}%`
      latest = snapped.rect
      useUi.getState().setDrag({ kind: 'free', guides: snapped.guides })
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      useUi.getState().setDrag(null)
      delete document.body.dataset.dragging
      delete document.body.dataset.dragId
      useStore.getState().setRect(id, latest)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  return (
    <article
      className={`pane${focused ? ' is-active' : ''}${pane.muted ? ' is-muted' : ''}${bell ? ' is-bell' : ''}`}
      data-pane={id}
      data-status={pane.status}
      style={{ ['--pane-accent' as string]: pane.accent }}
      onMouseDown={() => useStore.getState().focus(id)}
      onContextMenu={(event) => {
        event.preventDefault()
        openMenu(event.clientX, event.clientY)
      }}
    >
      <header
        className="titlebar"
        onPointerDown={onTitlePointerDown}
        onDoubleClick={(event) => {
          if ((event.target as HTMLElement).closest('.name')) return
          useStore.getState().toggleMaximize(id)
        }}
      >
        <div className="lights">
          <button className="light close" aria-label="Close pane" onClick={() => useStore.getState().closePane(id)}><i /></button>
          <button className="light min" aria-label="Shelf pane" onClick={() => useStore.getState().minimize(id)}><i /></button>
          <button className="light max" aria-label="Fill the desk" onClick={() => useStore.getState().toggleMaximize(id)}><i /></button>
        </div>
        <div className="title">
          <i className="dot" />
          {renaming ? (
            <input
              data-field="aether"
              value={draft}
              autoFocus
              onChange={(event) => setDraft(event.target.value)}
              onBlur={() => {
                useStore.getState().renamePane(id, draft)
                setRenaming(false)
              }}
              onKeyDown={(event) => {
                if (event.key === 'Enter') {
                  useStore.getState().renamePane(id, draft)
                  setRenaming(false)
                }
                if (event.key === 'Escape') setRenaming(false)
              }}
            />
          ) : (
            <span
              className="name"
              onDoubleClick={(event) => {
                event.stopPropagation()
                setDraft(pane.title)
                setRenaming(true)
              }}
            >
              {pane.title}
            </span>
          )}
          {pane.bell > 0 && !focused ? <em className="badge">{pane.bell}</em> : null}
          {broadcast && !pane.muted ? <em className="sync">sync</em> : null}
        </div>
        <div className="cwd" title={pane.cwd}>{prettyPath(pane.cwd, home)}</div>
      </header>
      {pane.offerRerun && pane.command ? (
        <div className="rerun">
          <button onClick={() => useStore.getState().rerun(id)}>Run again<span>{pane.command}</span></button>
          <button className="quiet" aria-label="Dismiss" onClick={() => useStore.getState().dismissRerun(id)}>×</button>
        </div>
      ) : null}
      <div className="term-host">
        <TerminalView id={id} onBell={() => setBell(true)} />
      </div>
      {findId === id ? (
        <form
          className="searchbar"
          onSubmit={(event) => {
            event.preventDefault()
            termApi(id)?.find(query, 'next')
          }}
        >
          <input
            data-field="aether"
            autoFocus
            placeholder="Find"
            value={query}
            onChange={(event) => {
              setQuery(event.target.value)
              termApi(id)?.find(event.target.value, 'next')
            }}
            onKeyDown={(event) => {
              if (event.key === 'Escape') useUi.getState().setFind(null)
              if (event.key === 'Enter' && event.shiftKey) {
                event.preventDefault()
                termApi(id)?.find(query, 'prev')
              }
            }}
          />
          <button type="button" onClick={() => termApi(id)?.find(query, 'prev')} aria-label="Previous">↑</button>
          <button type="submit" aria-label="Next">↓</button>
          <button type="button" onClick={() => useUi.getState().setFind(null)} aria-label="Close search">×</button>
        </form>
      ) : null}
      {pane.status === 'exited' ? (
        <div className="exitbar">
          <span>{pane.exitMessage || `Shell ended${pane.exitCode ? ` · code ${pane.exitCode}` : ''}`}</span>
          <button onClick={() => useStore.getState().restartShell(id)}>Restart</button>
          {pane.command ? <button onClick={() => useStore.getState().rerun(id)}>Run again</button> : null}
        </div>
      ) : null}
      {mode === 'free' && !locked ? (
        <>
          {(['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw'] as const).map((edge) => (
            <i key={edge} className={`resize ${edge}`} onPointerDown={(event) => onResize(edge, event)} />
          ))}
        </>
      ) : null}
    </article>
  )
}
