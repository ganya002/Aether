import { Component, useLayoutEffect, useRef, type ReactNode } from 'react'
import { chordLabel } from '../lib/keys'
import { getSlot, subscribeSlots } from '../lib/slots'
import { useStore, visibleIds } from '../lib/store'
import { useUi } from '../lib/ui'
import { Pane } from './Pane'
import { SplitTree } from './SplitTree'

class PaneBoundary extends Component<{ id: string; children: ReactNode }, { error: string | null }> {
  state = { error: null as string | null }
  static getDerivedStateFromError(error: Error) {
    return { error: error.message || 'This pane failed.' }
  }
  render() {
    if (!this.state.error) return this.props.children
    return (
      <div className="pane pane-failed">
        <p>{this.state.error}</p>
        <button className="primary" onClick={() => this.setState({ error: null })}>Reload pane</button>
      </div>
    )
  }
}

function Anchored({ id }: { id: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const mode = useStore((state) => state.active().mode)
  const rect = useStore((state) => state.active().rects[id])
  const z = useStore((state) => state.active().z[id] ?? 1)
  const maximized = useStore((state) => state.active().maximizedId === id)
  const anyMax = useStore((state) => Boolean(state.active().maximizedId))
  const active = useStore((state) => state.active().focusedId === id)

  useLayoutEffect(() => {
    const pane = ref.current
    if (!pane) return
    const stage = pane.closest('.stage') as HTMLElement | null
    if (!stage) return
    let ro: ResizeObserver | null = null
    let observed: HTMLElement | null = null
    const apply = () => {
      if (document.body.dataset.dragging === 'free' && document.body.dataset.dragId === id) return
      pane.style.visibility = ''
      pane.style.pointerEvents = ''
      if (maximized) {
        pane.style.left = '0px'
        pane.style.top = '0px'
        pane.style.width = `${stage.clientWidth}px`
        pane.style.height = `${stage.clientHeight}px`
        pane.style.zIndex = '6'
        return
      }
      if (anyMax) {
        pane.style.visibility = 'hidden'
        pane.style.pointerEvents = 'none'
      }
      if (mode === 'free' && rect) {
        pane.style.left = `${rect.x * 100}%`
        pane.style.top = `${rect.y * 100}%`
        pane.style.width = `${rect.w * 100}%`
        pane.style.height = `${rect.h * 100}%`
        pane.style.zIndex = String(10 + z)
        return
      }
      const slot = getSlot(id)
      if (!slot) {
        pane.style.visibility = 'hidden'
        return
      }
      const slotBox = slot.getBoundingClientRect()
      const stageBox = stage.getBoundingClientRect()
      pane.style.left = `${slotBox.left - stageBox.left}px`
      pane.style.top = `${slotBox.top - stageBox.top}px`
      pane.style.width = `${slotBox.width}px`
      pane.style.height = `${slotBox.height}px`
      pane.style.zIndex = active ? '3' : '2'
      if (observed !== slot) {
        ro?.disconnect()
        ro = new ResizeObserver(apply)
        ro.observe(slot)
        observed = slot
      }
    }
    apply()
    const stageObserver = new ResizeObserver(apply)
    stageObserver.observe(stage)
    const unsubscribe = subscribeSlots(apply)
    return () => {
      ro?.disconnect()
      stageObserver.disconnect()
      unsubscribe()
    }
  }, [active, anyMax, id, maximized, mode, rect, z])

  return (
    <div ref={ref} className="anchored" data-anchored={id}>
      <PaneBoundary id={id}>
        <Pane id={id} />
      </PaneBoundary>
    </div>
  )
}

export function Desktop() {
  const workspace = useStore((state) => state.active())
  const ids = visibleIds(workspace)
  const shelf = workspace.shelf
  const panes = useStore((state) => state.panes)

  return (
    <div className={`stage${workspace.focusMode ? ' focus-mode' : ''}${workspace.broadcast ? ' broadcast' : ''}${shelf.length ? ' has-shelf' : ''}${workspace.mode === 'free' ? ' free' : ''}`}>
      {workspace.mode === 'tile' ? (
        <div className="split-skeleton">
          <SplitTree node={workspace.tree} />
        </div>
      ) : null}
      <div className="pane-layer">
        {ids.map((id) => (
          <Anchored key={id} id={id} />
        ))}
      </div>
      {ids.length === 0 ? (
        <div className="empty">
          <h2>Nothing running on this desk.</h2>
          <p>Open a shell, then split it. Every pane is a real local terminal.</p>
          <div className="empty-actions">
            <button className="primary" onClick={() => useStore.getState().createPane()}>New terminal</button>
            <button onClick={() => useUi.getState().togglePalette()}>Run a command</button>
          </div>
          <p className="hint">
            <kbd>{chordLabel('t')}</kbd> new
            <kbd>{chordLabel('d')}</kbd> split
            <kbd>{chordLabel('k')}</kbd> run anything
          </p>
        </div>
      ) : null}
      {shelf.length ? (
        <div className="shelf">
          {shelf.map((id) => {
            const pane = panes[id]
            if (!pane) return null
            return (
              <button key={id} onClick={() => useStore.getState().restore(id)}>
                <i style={{ background: pane.accent }} />
                {pane.title}
              </button>
            )
          })}
        </div>
      ) : null}
    </div>
  )
}
