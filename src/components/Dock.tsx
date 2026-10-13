import {
  AppWindow,
  Columns2,
  Command,
  Image as ImageIcon,
  LayoutGrid,
  PanelLeft,
  PanelRight,
  Plus,
  Radio,
  Rows3,
  Settings2,
  Sparkles,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { chordLabel } from '../lib/keys'
import { useStore } from '../lib/store'
import { useUi } from '../lib/ui'
import { AppearanceFields } from './Fields'
import { Mark } from './Mark'

export function Dock() {
  const workspaces = useStore((state) => state.workspaces)
  const activeId = useStore((state) => state.activeWorkspaceId)
  const mode = useStore((state) => state.active().mode)
  const broadcast = useStore((state) => state.active().broadcast)
  const look = useUi((state) => state.look)
  const about = useUi((state) => state.about)
  const [renaming, setRenaming] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const lookRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!look && !about) return
    const close = (event: PointerEvent) => {
      const target = event.target as HTMLElement
      if (target.closest('.pop') || target.closest('[data-pop]')) return
      useUi.getState().setLook(false)
      useUi.getState().setAbout(false)
    }
    window.addEventListener('pointerdown', close)
    return () => window.removeEventListener('pointerdown', close)
  }, [about, look])

  return (
    <header className="dock" role="toolbar" aria-label="Aether">
      <button className="dock-brand" data-pop data-tip="About" onClick={() => useUi.getState().setAbout(!about)}>
        <Mark />
        <span className="word">Aether</span>
      </button>
      <i className="sep" />
      <div className="ws-row">
        {workspaces.map((workspace, index) =>
          renaming === workspace.id ? (
            <input
              key={workspace.id}
              data-field="aether"
              className="ws-input"
              value={draft}
              autoFocus
              onChange={(event) => setDraft(event.target.value)}
              onBlur={() => {
                useStore.getState().renameWorkspace(workspace.id, draft)
                setRenaming(null)
              }}
              onKeyDown={(event) => {
                if (event.key === 'Enter') {
                  useStore.getState().renameWorkspace(workspace.id, draft)
                  setRenaming(null)
                }
                if (event.key === 'Escape') setRenaming(null)
              }}
            />
          ) : (
            <button
              key={workspace.id}
              className={`ws${workspace.id === activeId ? ' on' : ''}`}
              data-tip={workspace.name}
              onClick={() => useStore.getState().switchWorkspace(workspace.id)}
              onDoubleClick={() => {
                setDraft(workspace.name)
                setRenaming(workspace.id)
              }}
              onContextMenu={(event) => {
                event.preventDefault()
                useUi.getState().openMenu(event.clientX, event.clientY, [
                  { id: 'rename', label: 'Rename desk', onSelect: () => { setDraft(workspace.name); setRenaming(workspace.id) } },
                  { id: 'close', label: 'Close desk', danger: true, onSelect: () => useStore.getState().closeWorkspace(workspace.id) },
                ])
              }}
            >
              {workspace.name.length < 8 ? workspace.name : index + 1}
            </button>
          ),
        )}
        <button className="icon" data-tip="New desk" aria-label="New desk" onClick={() => useStore.getState().addWorkspace()}>
          <Plus size={15} strokeWidth={1.75} />
        </button>
      </div>
      <i className="sep" />
      <div className="layout-row">
        <button className="icon" data-tip="Main and stack" aria-label="Main and stack" onClick={() => useStore.getState().arrangePattern('main')}><PanelLeft size={15} strokeWidth={1.75} /></button>
        <button className="icon" data-tip="Columns" aria-label="Columns" onClick={() => useStore.getState().arrangePattern('columns')}><Columns2 size={15} strokeWidth={1.75} /></button>
        <button className="icon" data-tip="Rows" aria-label="Rows" onClick={() => useStore.getState().arrangePattern('rows')}><Rows3 size={15} strokeWidth={1.75} /></button>
        <button className="icon" data-tip="Grid" aria-label="Grid" onClick={() => useStore.getState().arrangePattern('grid')}><LayoutGrid size={15} strokeWidth={1.75} /></button>
        <button className="icon" data-tip="Main on the right" aria-label="Main on the right" onClick={() => useStore.getState().arrangePattern('main-right')}><PanelRight size={15} strokeWidth={1.75} /></button>
        <button className="icon" data-tip={mode === 'tile' ? 'Freeform' : 'Tile'} aria-label="Toggle freeform" onClick={() => useStore.getState().toggleMode()}>
          {mode === 'tile' ? <AppWindow size={15} strokeWidth={1.75} /> : <LayoutGrid size={15} strokeWidth={1.75} />}
        </button>
        {mode === 'free' ? (
          <button className="icon" data-tip="Tidy" aria-label="Tidy windows" onClick={() => useStore.getState().tidy()}><Sparkles size={15} strokeWidth={1.75} /></button>
        ) : null}
      </div>
      <i className="sep" />
      <button className="icon" data-tip={`New terminal  ${chordLabel('t')}`} aria-label="New terminal" onClick={() => useStore.getState().createPane()}><Plus size={16} strokeWidth={1.75} /></button>
      <button className={`icon${broadcast ? ' on' : ''}`} data-tip="Broadcast keys" aria-label="Broadcast keys" aria-pressed={broadcast} onClick={() => useStore.getState().toggleBroadcast()}><Radio size={15} strokeWidth={1.75} /></button>
      <div className="pop-anchor" ref={lookRef}>
        <button className={`icon${look ? ' on' : ''}`} data-pop data-tip="Wallpaper and glass" aria-label="Wallpaper and glass" onClick={() => useUi.getState().setLook(!look)}>
          <ImageIcon size={15} strokeWidth={1.75} />
        </button>
        {look ? (
          <div className="pop look">
            <header>Look</header>
            <AppearanceFields compact />
          </div>
        ) : null}
        {about ? (
          <div className="pop about">
            <Mark size={26} />
            <strong>Aether</strong>
            <p>A glass desk for every CLI.</p>
            <p className="quiet">Shells stay on this machine. Nothing leaves it.</p>
          </div>
        ) : null}
      </div>
      <button className="icon" data-tip={`Commands  ${chordLabel('k')}`} aria-label="Commands" onClick={() => useUi.getState().togglePalette()}><Command size={15} strokeWidth={1.75} /></button>
      <button className="icon" data-tip="Settings" aria-label="Settings" onClick={() => useUi.getState().setSettings(true)}><Settings2 size={15} strokeWidth={1.75} /></button>
    </header>
  )
}
