import { Component, useEffect, type CSSProperties, type ReactNode } from 'react'
import { runShortcut } from './lib/actions'
import { matchShortcut } from './lib/keys'
import { session } from './lib/session'
import { useStore } from './lib/store'
import { termApi } from './lib/terms'
import { themeById } from './lib/themes'
import { toast, useUi } from './lib/ui'
import { Background } from './components/Background'
import { Desktop } from './components/Desktop'
import { Dock } from './components/Dock'
import { Mark } from './components/Mark'
import { Overlays } from './components/Overlays'
import { Palette } from './components/Palette'
import { Settings } from './components/Settings'

class DeskBoundary extends Component<{ children: ReactNode }, { error: string | null }> {
  state = { error: null as string | null }
  static getDerivedStateFromError(error: Error) {
    return { error: error.message || 'Something broke.' }
  }
  render() {
    if (this.state.error) {
      return (
        <div className="boot">
          <p>{this.state.error}</p>
          <button className="primary" onClick={() => this.setState({ error: null })}>Try again</button>
        </div>
      )
    }
    return this.props.children
  }
}

function Shell() {
  const settings = useStore((state) => state.settings)
  const theme = themeById(settings.themeId)
  const accent = settings.accent || theme.accent
  const title = useStore((state) => {
    const workspace = state.active()
    const pane = workspace.focusedId ? state.panes[workspace.focusedId] : undefined
    return pane ? `${pane.title} — Aether` : 'Aether'
  })

  useEffect(() => {
    document.title = title
  }, [title])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const ui = useUi.getState()
      if (event.key === 'Escape') {
        if (ui.menu) {
          ui.closeMenu()
          return
        }
        if (ui.palette) {
          ui.setPalette(false)
          event.preventDefault()
          return
        }
        if (ui.settings) {
          ui.setSettings(false)
          event.preventDefault()
          return
        }
        if (ui.look || ui.about) {
          ui.setLook(false)
          ui.setAbout(false)
          return
        }
        if (ui.findId) {
          ui.setFind(null)
          event.preventDefault()
          return
        }
        const workspace = useStore.getState().active()
        if (workspace.maximizedId) {
          useStore.getState().clearMaximize()
          event.preventDefault()
          return
        }
        if (workspace.focusMode) {
          useStore.getState().toggleFocusMode()
          event.preventDefault()
        }
        return
      }
      const shortcut = matchShortcut(event)
      if (!shortcut) return
      const target = event.target as HTMLElement | null
      const typing = Boolean(target?.closest('[data-field="aether"]'))
      const browserLevel = shortcut === 'close' || shortcut === 'new' || shortcut === 'new-here' || shortcut === 'desk-new'
      if (typing && shortcut !== 'palette') {
        if (browserLevel) event.preventDefault()
        return
      }
      if (event.repeat && !shortcut.startsWith('font') && !shortcut.startsWith('resize') && !shortcut.startsWith('focus-')) return
      event.preventDefault()
      event.stopPropagation()
      runShortcut(shortcut)
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [])

  useEffect(() => {
    return useUi.subscribe((state, previous) => {
      const wasOpen = previous.palette || previous.settings || previous.look
      const isOpen = state.palette || state.settings || state.look
      if (wasOpen && !isOpen) {
        const id = useStore.getState().active().focusedId
        termApi(id)?.focus()
      }
    })
  }, [])

  const style = {
    '--fg': theme.fg,
    '--muted': theme.muted,
    '--faint': theme.faint,
    '--line': theme.line,
    '--line-strong': theme.lineStrong,
    '--accent': accent,
    '--scrim': theme.scrim,
    '--scrim-a': String(settings.scrim),
    '--blur': settings.performance ? '0px' : `${settings.blur}px`,
    '--gap': `${settings.gap}px`,
    '--radius': `${settings.radius}px`,
    '--pad': `${settings.pad}px`,
    '--shadow': theme.shadow,
    '--vignette': theme.vignette,
    '--bg-dim': String(settings.bgDim),
  } as CSSProperties

  return (
    <div id="app" data-tone={theme.tone} data-performance={settings.performance ? 'on' : 'off'} style={style}>
      <Background />
      <Dock />
      <Desktop />
      <Palette />
      <Settings />
      <Overlays />
    </div>
  )
}

export function App() {
  const hydrated = useStore((state) => state.hydrated)
  const failed = useUi((state) => state.connected)

  useEffect(() => {
    let cancelled = false
    const boot = async () => {
      try {
        const token = document.querySelector('meta[name="aether-token"]')?.getAttribute('content') ?? ''
        const [metaRes, stateRes, bgRes] = await Promise.all([
          fetch('/api/meta'),
          fetch('/api/state'),
          fetch('/api/backgrounds'),
        ])
        if (!metaRes.ok) throw new Error('The shell host is not answering.')
        const meta = (await metaRes.json()) as { bootId: string; shell: string; home: string; platform: string }
        const saved = (await stateRes.json()) as { state: unknown }
        const backgrounds = (await bgRes.json()) as { images?: Array<{ id: string; url: string }> }
        if (cancelled) return
        session.onConnect(async () => {
          const fresh = (await fetch('/api/meta').then((response) => response.json())) as { bootId: string }
          const current = useStore.getState()
          if (current.bootId && fresh.bootId !== current.bootId) current.noteRestart()
          if (current.bootId !== fresh.bootId) current.setBootId(fresh.bootId)
          session.reattachMounted()
        })
        session.onGlobal((message) => {
          if (message.t === 'ready') {
            useStore.getState().markReady(message.id, { pid: message.pid, cwd: message.cwd, shell: message.shell })
          } else if (message.t === 'exit') {
            useStore.getState().markExit(message.id, message.code)
          } else if (message.t === 'cwd') {
            useStore.getState().setCwd(message.id, message.cwd)
          } else if (message.t === 'error') {
            toast(message.message)
            if (message.id) useStore.getState().markExit(message.id, 1, message.message)
          }
        })
        session.onStatus((status) => useUi.getState().setConnected(status))
        useStore.getState().hydrate(saved.state, meta, backgrounds.images ?? [])
        session.start(token)
      } catch (error) {
        if (!cancelled) {
          useUi.getState().setConnected('closed')
          toast(error instanceof Error ? error.message : 'Could not start')
        }
      }
    }
    void boot()
    const onDrop = (event: DragEvent) => {
      const target = event.target as HTMLElement | null
      if (target?.closest('.pane, .dock, .pop, .palette, .settings')) return
      const file = [...(event.dataTransfer?.files ?? [])].find((item) => item.type.startsWith('image/'))
      if (!file) return
      event.preventDefault()
      void fetch('/api/backgrounds', {
        method: 'POST',
        headers: { 'content-type': file.type, 'x-filename': file.name },
        body: file,
      })
        .then((response) => response.json())
        .then((json: { id?: string; url?: string }) => {
          if (!json.id || !json.url) return
          const store = useStore.getState()
          store.setUploads([...store.uploads, { id: json.id!, url: json.url! }])
          store.chooseBackground({ kind: 'image', id: json.id })
        })
        .catch(() => toast('Could not use that image'))
    }
    const onDragOver = (event: DragEvent) => {
      if ([...(event.dataTransfer?.types ?? [])].includes('Files')) event.preventDefault()
    }
    window.addEventListener('drop', onDrop)
    window.addEventListener('dragover', onDragOver)
    return () => {
      cancelled = true
      session.stop()
      window.removeEventListener('drop', onDrop)
      window.removeEventListener('dragover', onDragOver)
    }
  }, [])

  if (!hydrated) {
    return (
      <div id="app" data-tone="dark">
        <div className="boot">
          <Mark size={28} />
          <p>{failed === 'closed' ? 'The shell host is not answering.' : 'Starting shells…'}</p>
          {failed === 'closed' ? <button className="primary" onClick={() => location.reload()}>Retry</button> : null}
        </div>
      </div>
    )
  }

  return (
    <DeskBoundary>
      <Shell />
    </DeskBoundary>
  )
}
