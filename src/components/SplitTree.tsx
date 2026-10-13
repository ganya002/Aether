import { useLayoutEffect, useRef } from 'react'
import { count, type LayoutNode, type SplitNode } from '../lib/layout'
import { registerSlot } from '../lib/slots'
import { useStore } from '../lib/store'

function Slot({ id, grow }: { id: string; grow: number }) {
  const ref = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    return registerSlot(id, el)
  }, [id])
  return <div ref={ref} className="split-slot" data-slot={id} style={{ flex: `${grow} 1 0px` }} />
}

function Handle({ node }: { node: SplitNode }) {
  const onPointerDown = (event: React.PointerEvent) => {
    if (event.button !== 0) return
    if (useStore.getState().active().locked) return
    event.preventDefault()
    const parent = event.currentTarget.parentElement as HTMLElement
    const first = parent.children[0] as HTMLElement
    const last = parent.children[2] as HTMLElement
    let latest = node.ratio
    document.body.dataset.dragging = '1'
    const move = (ev: PointerEvent) => {
      const bounds = parent.getBoundingClientRect()
      const raw = node.dir === 'row' ? (ev.clientX - bounds.left) / bounds.width : (ev.clientY - bounds.top) / bounds.height
      latest = Math.min(0.92, Math.max(0.08, raw))
      first.style.flex = `${latest} 1 0px`
      last.style.flex = `${1 - latest} 1 0px`
    }
    const up = () => {
      delete document.body.dataset.dragging
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      useStore.getState().setRatio(node.id, latest)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  return (
    <div
      className={`split-handle ${node.dir}`}
      onPointerDown={onPointerDown}
      onDoubleClick={() => useStore.getState().setRatio(node.id, count(node.a) / count(node))}
      role="separator"
      aria-orientation={node.dir === 'row' ? 'vertical' : 'horizontal'}
    />
  )
}

function Branch({ node, grow }: { node: LayoutNode; grow: number }) {
  if (node.type === 'pane') return <Slot id={node.id} grow={grow} />
  return (
    <div className="split-branch" style={{ flex: `${grow} 1 0px` }}>
      <Split node={node} />
    </div>
  )
}

function Split({ node }: { node: SplitNode }) {
  return (
    <div className={`split ${node.dir}`} data-split={node.id}>
      <Branch node={node.a} grow={node.ratio} />
      <Handle node={node} />
      <Branch node={node.b} grow={1 - node.ratio} />
    </div>
  )
}

export function SplitTree({ node }: { node: LayoutNode | null }) {
  if (!node) return null
  if (node.type === 'pane') return <Slot id={node.id} grow={1} />
  return <Split node={node} />
}
