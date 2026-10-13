import { useEffect, useState } from 'react'
import type { DropPreview } from '../lib/ui'
import { useUi } from '../lib/ui'

function zoneBox(drop: DropPreview) {
  const { left, top, width, height, zone } = drop
  if (zone === 'left') return { left, top, width: width / 2, height }
  if (zone === 'right') return { left: left + width / 2, top, width: width / 2, height }
  if (zone === 'top') return { left, top, width, height: height / 2 }
  if (zone === 'bottom') return { left, top: top + height / 2, width, height: height / 2 }
  const insetX = width * 0.2
  const insetY = height * 0.22
  return { left: left + insetX, top: top + insetY, width: width - insetX * 2, height: height - insetY * 2 }
}

const ZONE_LABEL: Record<DropPreview['zone'], string> = {
  left: 'Split left',
  right: 'Split right',
  top: 'Split up',
  bottom: 'Split down',
  center: 'Swap',
}

export function Overlays() {
  const drag = useUi((state) => state.drag)
  const menu = useUi((state) => state.menu)
  const toasts = useUi((state) => state.toasts)
  const hud = useUi((state) => state.hud)
  const connected = useUi((state) => state.connected)
  const [banner, setBanner] = useState(false)

  useEffect(() => {
    if (connected === 'open') {
      setBanner(false)
      return
    }
    const timer = window.setTimeout(() => setBanner(true), 450)
    return () => window.clearTimeout(timer)
  }, [connected])

  useEffect(() => {
    if (!menu) return
    const close = () => useUi.getState().closeMenu()
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') close()
    }
    window.addEventListener('pointerdown', close)
    window.addEventListener('keydown', onKey)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('pointerdown', close)
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('resize', close)
    }
  }, [menu])

  const stage = typeof document !== 'undefined' ? document.querySelector('.stage')?.getBoundingClientRect() : undefined

  return (
    <>
      {banner ? <div className="banner">{connected === 'connecting' ? 'Connecting to the shell host…' : 'Reconnecting…'}</div> : null}
      {drag?.kind === 'tile' ? (
        <>
          <div className="ghost" style={{ left: drag.x, top: drag.y }}>
            <i style={{ background: drag.accent }} />
            {drag.title}
          </div>
          {drag.drop ? (
            <div className="drop" style={zoneBox(drag.drop)}>
              {ZONE_LABEL[drag.drop.zone]}
            </div>
          ) : null}
        </>
      ) : null}
      {drag?.kind === 'free' && stage
        ? drag.guides.map((guide, index) =>
            guide.axis === 'x' ? (
              <div key={`${guide.axis}-${index}`} className="guide v" style={{ left: stage.left + guide.pos * stage.width }} />
            ) : (
              <div key={`${guide.axis}-${index}`} className="guide h" style={{ top: stage.top + guide.pos * stage.height }} />
            ),
          )
        : null}
      {menu ? (
        <div
          className="menu"
          style={{ left: Math.max(8, Math.min(menu.x, window.innerWidth - 230)), top: Math.max(8, Math.min(menu.y, window.innerHeight - 280)) }}
          onPointerDown={(event) => event.stopPropagation()}
        >
          {menu.items.map((item) => (
            <button
              key={item.id}
              className={item.danger ? 'danger' : ''}
              disabled={item.disabled}
              onClick={() => {
                item.onSelect()
                useUi.getState().closeMenu()
              }}
            >
              <span>{item.label}</span>
              {item.hint ? <em>{item.hint}</em> : null}
            </button>
          ))}
        </div>
      ) : null}
      {hud ? <div className="hud">{hud}</div> : null}
      <div className="toasts">
        {toasts.map((item) => (
          <div key={item.id} className="toast">{item.text}</div>
        ))}
      </div>
    </>
  )
}
